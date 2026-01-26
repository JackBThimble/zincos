const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const KHeap = struct {
    pub const ALIGN_MIN: usize = 16;
    pub const BACKPTR_SIZE: usize = @sizeOf(usize);

    // Simple segregated bins (size classes). 0..N-1; each is a doubly-linked list of free blocks.
    const BIN_COUNT = 32;

    mapper: *vmm.Mapper,

    base: u64, // heap virtual base (page aligned)
    size: u64, // heap virtual size (page aligned)
    mapped_end: u64, // end of mapped heap (virtual)
    wilderness: *Header, // last free block (always at end of mapped heap)

    bins: [BIN_COUNT]?*Header = [_]?*Header{null} ** BIN_COUNT,

    const USED_FLAG: usize = 1;

    const Header = extern struct {
        size_and_flags: usize,
        user_size: usize,
        prev_free: ?*Header,
        next_free: ?*Header,
    };

    comptime {
        // Keep it aligned and predictable
        if (@sizeOf(Header) != 32) @compileError("Header size unexpected; adjust padding.");
    }

    inline fn isUsed(h: *const Header) bool {
        return (h.size_and_flags & USED_FLAG) != 0;
    }

    inline fn setUsed(h: *Header, used: bool) void {
        if (used) h.size_and_flags |= USED_FLAG else h.size_and_flags &= ~USED_FLAG;
    }

    inline fn blkSize(h: *const Header) usize {
        return h.size_and_flags & ~USED_FLAG;
    }

    inline fn footerPtr(h: *Header) *usize {
        const start = @intFromPtr(h);
        const end = start + blkSize(h) - @sizeOf(usize);
        return @ptrFromInt(end);
    }

    inline fn writeFooter(h: *Header) void {
        footerPtr(h).* = h.size_and_flags;
    }

    inline fn nextHeader(h: *Header) *Header {
        return @ptrFromInt(@intFromPtr(h) + blkSize(h));
    }

    inline fn prevHeader(self: *KHeap, h: *Header) ?*Header {
        const start = @intFromPtr(h);
        const base_u = @as(usize, @intCast(self.base));

        if (start < base_u + @sizeOf(usize)) return null;

        // If at heap base, no previous header
        // caller should check bounds; free path does it with base
        const prev_footer_addr = start - @sizeOf(usize);
        const prev_tag: usize = @as(*usize, @ptrFromInt(prev_footer_addr)).*;
        const prev_size = (prev_tag & ~USED_FLAG);
        if (prev_size == 0) return null;
        if (prev_size > (start - base_u)) return null;
        return @ptrFromInt(start - prev_size);
    }

    inline fn alignUpUsize(x: usize, a: usize) usize {
        return (x + a - 1) & ~(a - 1);
    }
    inline fn alignUpU64(x: u64, a: u64) u64 {
        return (x + a - 1) & ~(a - 1);
    }

    inline fn minBlockSize() usize {
        // header + footer + at least ALIGN_MIN bytes payload-ish room
        return @sizeOf(Header) + @sizeOf(usize) + ALIGN_MIN;
    }

    fn binIndex(sz: usize) usize {
        // power-ish buckets. Clamp
        // smallest bin covers upt to 32..64 etc; good enough for kernel heap.
        const s = @max(sz, minBlockSize());
        // log2 ceil
        const msb = (std.math.log2_int(usize, s));
        return @min(msb, BIN_COUNT - 1);
    }

    fn removeFree(self: *KHeap, h: *Header) void {
        std.debug.assert(!isUsed(h));
        const idx = binIndex(blkSize(h));

        if (h.prev_free) |p| p.next_free = h.next_free else self.bins[idx] = h.next_free;
        if (h.next_free) |n| n.prev_free = h.prev_free;

        h.prev_free = null;
        h.next_free = null;
    }

    fn insertFree(self: *KHeap, h: *Header) void {
        std.debug.assert(!isUsed(h));
        const idx = binIndex(blkSize(h));

        h.prev_free = null;
        h.next_free = self.bins[idx];
        if (self.bins[idx]) |head| head.prev_free = h;
        self.bins[idx] = h;
    }

    fn mapMore(self: *KHeap, need_bytes: usize) bool {
        // Ensure wilderness has at least need_bytes.
        var want_end = @as(u64, @intCast(@intFromPtr(self.wilderness))) + @as(u64, @intCast(need_bytes));
        want_end = alignUpU64(want_end, pmm.PAGE_SIZE);

        const heap_end = self.base + self.size;
        if (want_end > heap_end) return false;

        const w = self.wilderness;
        std.debug.assert(!isUsed(w));
        self.removeFree(w);

        while (self.mapped_end < want_end) : (self.mapped_end += pmm.PAGE_SIZE) {
            const frame = self.mapper.fa.allocFrame() orelse {
                self.insertFree(w);
                return false;
            };

            var flags: u64 = 0;
            flags |= vmm.PTE_PRESENT;
            flags |= vmm.PTE_WRITABLE;
            flags |= vmm.PTE_NX;

            self.mapper.map4k(self.mapped_end, frame, flags);
        }

        // Grow wilderness block to mapped end
        const new_size = @as(usize, @intCast(self.mapped_end - @as(u64, @intCast(@intFromPtr(w)))));
        w.size_and_flags = new_size;
        writeFooter(w);

        self.insertFree(w);
        return true;
    }

    fn splitBlock(self: *KHeap, h: *Header, want: usize) *Header {
        // h is free and large enough. split if leftover is big enough
        const total = blkSize(h);
        std.debug.assert(total >= want);

        const leftover = total - want;
        if (leftover >= minBlockSize()) {
            // allocated part = first, free remainder = second
            h.size_and_flags = want | USED_FLAG;
            writeFooter(h);

            const rem: *Header = @ptrFromInt(@intFromPtr(h) + want);
            rem.size_and_flags = leftover;
            rem.prev_free = null;
            rem.next_free = null;
            rem.user_size = 0;
            writeFooter(rem);

            // if h was wilderness, update wilderness to rem
            if (h == self.wilderness) {
                self.wilderness = rem;
            }

            // insert remainder into bins
            insertFree(self, rem);
        } else {
            // take whole block
            h.size_and_flags = total | USED_FLAG;
            writeFooter(h);

            // If we consumed wilderness entirely, make a new wilderness by mapping at least one block
            // (but easiest: keep unused; next alloc will force mapMore and then coalesce on free)
        }
        return h;
    }

    fn findFit(self: *KHeap, want: usize) ?*Header {
        var idx = binIndex(want);
        while (idx < BIN_COUNT) : (idx += 1) {
            var cur = self.bins[idx];
            while (cur) |h| : (cur = h.next_free) {
                if (blkSize(h) >= want) return h;
            }
        }
        return null;
    }

    fn coalesce(self: *KHeap, h_in: *Header) *Header {
        var h = h_in;
        std.debug.assert(!isUsed(h));

        // try merge with next if free and within mapped range
        const heap_mapped_end_usize: usize = @intCast(self.mapped_end);
        const next = nextHeader(h);
        if (@intFromPtr(next) < heap_mapped_end_usize and !isUsed(next)) {
            removeFree(self, next);
            h.size_and_flags = (blkSize(h) + blkSize(next));
            writeFooter(h);

            if (next == self.wilderness)
                self.wilderness = h;
        }

        // try merge with prev if free and within heap base
        const heap_base_usize: usize = @intCast(self.base);
        const h_addr = @intFromPtr(h);
        if (h_addr > heap_base_usize + @sizeOf(Header)) {
            const prev = self.prevHeader(h) orelse return h;
            if (@intFromPtr(prev) >= heap_base_usize and !isUsed(prev)) {
                removeFree(self, prev);
                prev.size_and_flags = (blkSize(prev) + blkSize(h));
                writeFooter(prev);

                if (h == self.wilderness) self.wilderness = prev;
                h = prev;
            }
        }
        return h;
    }

    // ========================================
    // Public API
    // ========================================
    pub fn init(mapper: *vmm.Mapper, heap_base: u64, heap_size: u64) KHeap {
        std.debug.assert((heap_size & (pmm.PAGE_SIZE - 1)) == 0);
        std.debug.assert((heap_base & (pmm.PAGE_SIZE - 1)) == 0);

        var self = KHeap{
            .mapper = mapper,
            .base = heap_base,
            .size = heap_size,
            .mapped_end = heap_base,
            .wilderness = undefined,
            .bins = [_]?*Header{null} ** BIN_COUNT,
        };

        // Map an initial chunk (at least 1 page)
        self.mapped_end = heap_base;
        const ok = self.mapMore(minBlockSize());
        if (!ok) @panic("[KHeap.init] Failed to map initial heap");

        const w: *Header = @ptrFromInt(@as(usize, @intCast(heap_base)));
        w.size_and_flags = @as(usize, @intCast(self.mapped_end - heap_base));
        w.prev_free = null;
        w.next_free = null;
        w.user_size = 0;
        writeFooter(w);

        self.wilderness = w;
        self.insertFree(w);

        return self;
    }

    pub fn kmalloc(self: *KHeap, size: usize, alignment: usize) ?[*]u8 {
        const a = @max(alignment, ALIGN_MIN);
        std.debug.assert(std.math.isPowerOfTwo(a));

        // always return an aligned pointer but may need padding + backptr.
        // layout inside payload:
        //      [ ... padding ... ][ backptr usize ][ user-bytes ... ]
        const needed_payload = size + BACKPTR_SIZE + (a - 1);
        const want = alignUpUsize(@sizeOf(Header) + needed_payload + @sizeOf(usize), ALIGN_MIN);
        const want2 = @max(want, minBlockSize());

        const h = self.findFit(want2) orelse blk: {
            // no fit: grow wilderness then retry
            if (!self.mapMore(want2)) return null;
            break :blk self.findFit(want2) orelse return null;
        };

        self.removeFree(h);
        const ah = self.splitBlock(h, want2);
        ah.user_size = size;

        // compute aligned return pointer from payload start.
        const payload_start = @intFromPtr(ah) + @sizeOf(Header);
        const with_backptr = payload_start + BACKPTR_SIZE;
        const user_ptr = alignUpUsize(with_backptr, a);

        // store header back-pointer right before the returned pointer.
        const backptr_addr = user_ptr - BACKPTR_SIZE;
        @as(*usize, @ptrFromInt(backptr_addr)).* = @intFromPtr(ah);

        return @ptrFromInt(user_ptr);
    }

    pub fn kfree(self: *KHeap, ptr: [*]u8) void {
        const p = @intFromPtr(ptr);

        if (p < @as(usize, @intCast(self.base)) or p >= @as(usize, @intCast(self.base + self.size)))
            @panic("kfree: ptr outside heap");

        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;

        if (h_addr < @as(usize, @intCast(self.base)) or h_addr >= @as(usize, @intCast(self.base + self.size)))
            @panic("kfree: header outside heap");

        const h: *Header = @ptrFromInt(h_addr);

        if (!isUsed(h)) @panic("kfree: double free or corrupt header");

        // Mark free
        setUsed(h, false);
        writeFooter(h);

        // Coalesce and put in bins
        const merged = self.coalesce(h);

        // Ensure wilderness points at last block if we merged to end.
        // (If merged touches mapped_end, it *is* wilderness)
        const end = @intFromPtr(merged) + blkSize(merged);
        if (end == @as(usize, @intCast(self.mapped_end))) self.wilderness = merged;

        self.insertFree(merged);
    }

    pub fn krealloc(self: *KHeap, old_ptr: ?[*]u8, new_size: usize, alignment: usize) ?[*]u8 {
        if (old_ptr == null) return self.kmalloc(new_size, alignment);
        if (new_size == 0) {
            self.kfree(old_ptr.?);
            return null;
        }

        const old = old_ptr.?;

        const p = @intFromPtr(old);
        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;
        const h: *Header = @ptrFromInt(h_addr);

        const old_size = h.user_size;
        const copy_n = @min(new_size, old_size);

        const new_ptr = self.kmalloc(new_size, alignment) orelse return null;

        @memcpy(new_ptr[0..copy_n], old[0..copy_n]);
        self.kfree(old);
        return new_ptr;
    }
};
