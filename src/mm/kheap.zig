const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const builtin = @import("builtin");
const log = @import("shared").log;

/// Flags for heap pages: writable, not executable
const HEAP_PAGE_FLAGS = vmm.MapFlags{ .writable = true };

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const KHeap = struct {
    pub const ALIGN_MIN: usize = 16;
    pub const BACKPTR_SIZE: usize = @sizeOf(usize);

    // Simple segregated bins (size classes). 0..N-1; each is a doubly-linked list of free blocks.
    const BIN_COUNT = 32;

    // Magic numbers for corruption detection
    const HEADER_MAGIC: usize = 0xA110_CA7E_BEEF_F00D; // "ALLOCATE BEEF FOOD"
    const FREE_MAGIC: usize = 0xDEAD_F2EE_DEAD_F2EE; // "DEAD FREE" (F2EE = FREE)
    const POISON_BYTE: u8 = 0xFE; // Fill freed memory in debug builds

    // Enable expensive checks in debug/safe builds
    const DEBUG_CHECKS = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

    mapper: vmm.Mapper,

    base: u64, // heap virtual base (page aligned)
    size: u64, // heap virtual size (page aligned)
    mapped_end: u64, // end of mapped heap (virtual)
    wilderness: *Header, // last free block (always at end of mapped heap)

    bins: [BIN_COUNT]?*Header = [_]?*Header{null} ** BIN_COUNT,

    lock: SpinLock = .{},

    // Statistics (always tracked)
    total_allocs: usize = 0,
    total_frees: usize = 0,
    current_allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,

    const USED_FLAG: usize = 1;

    const Header = extern struct {
        magic: usize, // HEADER_MAGIC when allocated, FREE_MAGIC when free
        size_and_flags: usize,
        user_size: usize,
        prev_free: ?*Header,
        next_free: ?*Header,
        _padding: [8]u8, // Pad to 48 bytes for alignment
    };

    comptime {
        // Keep it aligned and predictable
        if (@sizeOf(Header) != 48) @compileError("Header size unexpected; adjust padding.");
    }

    // ========================================
    // Header Validation
    // ========================================

    /// Validate a header's magic number and basic sanity
    fn validateHeader(self: *const KHeap, h: *const Header, expect_used: ?bool) bool {
        const h_addr = @intFromPtr(h);
        const base_u = @as(usize, @intCast(self.base));
        const mapped_end_u = @as(usize, @intCast(self.mapped_end));

        // Check header is within heap bounds
        if (h_addr < base_u or h_addr >= mapped_end_u) return false;

        // Check magic
        const expected_magic = if (expect_used) |used|
            (if (used) HEADER_MAGIC else FREE_MAGIC)
        else
            null;

        if (expected_magic) |magic| {
            if (h.magic != magic) return false;
        } else {
            // Accept either magic
            if (h.magic != HEADER_MAGIC and h.magic != FREE_MAGIC) return false;
        }

        // Check size is reasonable
        const sz = blkSize(h);
        if (sz < minBlockSize()) return false;
        if (h_addr + sz > mapped_end_u) return false;

        // Check alignment
        if ((sz & (ALIGN_MIN - 1)) != 0) return false;

        return true;
    }

    /// Panic with detailed info if header is invalid
    fn assertValidHeader(self: *const KHeap, h: *const Header, expect_used: ?bool, context: []const u8) void {
        if (!DEBUG_CHECKS) return;

        if (!self.validateHeader(h, expect_used)) {
            log.err("\n[HEAP CORRUPTION] {s}", .{context});
            log.err("\tHeader addr: 0x{x}", .{@intFromPtr(h)});
            log.err("\tMagic: 0x{x} (expected: ALLOC=0x{x} or FREE=0x{x})", .{ h.magic, HEADER_MAGIC, FREE_MAGIC });
            log.err("\tSize: {} (min={})", .{ blkSize(h), minBlockSize() });
            log.err("\tHeap base: 0x{x}, mapped_end: 0x{x}", .{ self.base, self.mapped_end });
            @panic("heap corruption detected");
        }
    }

    inline fn isUsed(h: *const Header) bool {
        return (h.size_and_flags & USED_FLAG) != 0;
    }

    inline fn setUsed(h: *Header, used: bool) void {
        if (used) {
            h.size_and_flags |= USED_FLAG;
            h.magic = HEADER_MAGIC;
        } else {
            h.size_and_flags &= ~USED_FLAG;
            h.magic = FREE_MAGIC;
        }
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

    /// Verify footer matches header
    fn verifyFooter(h: *const Header) bool {
        const footer = @as(*const usize, @ptrFromInt(@intFromPtr(h) + blkSize(h) - @sizeOf(usize))).*;
        return footer == h.size_and_flags;
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

    /// Poison freed memory to catch use-after-free
    fn poisonBlock(h: *Header) void {
        if (!DEBUG_CHECKS) return;

        const payload_start = @intFromPtr(h) + @sizeOf(Header);
        const payload_end = @intFromPtr(h) + blkSize(h) - @sizeOf(usize);
        if (payload_end > payload_start) {
            const payload: [*]u8 = @ptrFromInt(payload_start);
            @memset(payload[0..(payload_end - payload_start)], POISON_BYTE);
        }
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
        // Check if wilderness was entirely consumed (now used) - need to create fresh wilderness
        const wilderness_consumed = isUsed(self.wilderness);

        const wilderness_addr = if (wilderness_consumed)
            self.mapped_end // Start fresh at end of mapped memory
        else
            @as(u64, @intCast(@intFromPtr(self.wilderness)));

        var want_end = wilderness_addr + @as(u64, @intCast(need_bytes));
        want_end = alignUpU64(want_end, pmm.PAGE_SIZE);

        const heap_end = self.base + self.size;
        if (want_end > heap_end) return false;

        // Only remove from free list if wilderness is actually free
        if (!wilderness_consumed) {
            self.removeFree(self.wilderness);
        }

        const old_mapped_end = self.mapped_end;

        while (self.mapped_end < want_end) : (self.mapped_end += pmm.PAGE_SIZE) {
            const frame = self.mapper.allocFrame() orelse {
                // Restore wilderness if we failed partway through
                if (!wilderness_consumed and self.mapped_end > old_mapped_end) {
                    // Grew some pages, update wilderness size
                    const new_size = @as(usize, @intCast(self.mapped_end - @as(u64, @intCast(@intFromPtr(self.wilderness)))));
                    self.wilderness.size_and_flags = new_size;
                    writeFooter(self.wilderness);
                    self.insertFree(self.wilderness);
                } else if (!wilderness_consumed) {
                    self.insertFree(self.wilderness);
                }
                // If wilderness was consumed and we failed to map any pages, there's no free wilderness
                return false;
            };

            self.mapper.mapKernel4k(self.mapped_end, frame, HEAP_PAGE_FLAGS);
        }

        if (wilderness_consumed) {
            // Create a fresh wilderness block at the old mapped_end
            const w: *Header = @ptrFromInt(@as(usize, @intCast(old_mapped_end)));
            const new_size = @as(usize, @intCast(self.mapped_end - old_mapped_end));
            w.magic = FREE_MAGIC;
            w.size_and_flags = new_size;
            w.prev_free = null;
            w.next_free = null;
            w.user_size = 0;
            w._padding = [_]u8{0} ** 8;
            writeFooter(w);
            self.wilderness = w;
            self.insertFree(w);
        } else {
            // Grow existing wilderness block to mapped end
            const new_size = @as(usize, @intCast(self.mapped_end - @as(u64, @intCast(@intFromPtr(self.wilderness)))));
            self.wilderness.size_and_flags = new_size;
            writeFooter(self.wilderness);
            self.insertFree(self.wilderness);
        }

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
            rem.magic = FREE_MAGIC;
            rem.size_and_flags = leftover;
            rem.prev_free = null;
            rem.next_free = null;
            rem.user_size = 0;
            rem._padding = [_]u8{0} ** 8;
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
    pub fn init(mapper: vmm.Mapper, heap_base: u64, heap_size: u64) KHeap {
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

        // Map initial page(s) manually - cannot use mapMore() because wilderness is not yet valid
        const initial_pages = alignUpU64(minBlockSize(), pmm.PAGE_SIZE);
        var mapped: u64 = 0;
        while (mapped < initial_pages) : (mapped += pmm.PAGE_SIZE) {
            const frame = mapper.allocFrame() orelse @panic("[KHeap.init] Failed to allocate initial frame");
            mapper.mapKernel4k(heap_base + mapped, frame, HEAP_PAGE_FLAGS);
        }
        self.mapped_end = heap_base + mapped;

        // Set up the initial wilderness block spanning all mapped memory
        const w: *Header = @ptrFromInt(@as(usize, @intCast(heap_base)));
        w.magic = FREE_MAGIC;
        w.size_and_flags = @as(usize, @intCast(self.mapped_end - heap_base));
        w.prev_free = null;
        w.next_free = null;
        w.user_size = 0;
        w._padding = [_]u8{0} ** 8;
        writeFooter(w);

        self.wilderness = w;
        self.insertFree(w);

        return self;
    }

    pub fn kmalloc(self: *KHeap, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;

        self.lock.acquire();
        defer self.lock.release();

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

        // Validate free block before using it
        self.assertValidHeader(h, false, "kmalloc: found corrupt free block");

        self.removeFree(h);
        const ah = self.splitBlock(h, want2);
        ah.user_size = size;
        ah.magic = HEADER_MAGIC; // Mark as allocated

        // compute aligned return pointer from payload start.
        const payload_start = @intFromPtr(ah) + @sizeOf(Header);
        const with_backptr = payload_start + BACKPTR_SIZE;
        const user_ptr = alignUpUsize(with_backptr, a);

        // store header back-pointer right before the returned pointer.
        const backptr_addr = user_ptr - BACKPTR_SIZE;
        @as(*usize, @ptrFromInt(backptr_addr)).* = @intFromPtr(ah);

        // Update statistics
        self.total_allocs += 1;
        self.current_allocated_bytes += size;
        if (self.current_allocated_bytes > self.peak_allocated_bytes) {
            self.peak_allocated_bytes = self.current_allocated_bytes;
        }

        return @ptrFromInt(user_ptr);
    }

    pub fn kfree(self: *KHeap, ptr: [*]u8) void {
        self.lock.acquire();
        defer self.lock.release();

        const p = @intFromPtr(ptr);
        const base_u = @as(usize, @intCast(self.base));
        const heap_end_u = @as(usize, @intCast(self.base + self.size));

        // Validate pointer is within heap virtual range
        if (p < base_u or p >= heap_end_u) {
            @panic("kfree: ptr outside heap bounds");
        }

        // Get header address from backpointer
        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;

        // Validate header address
        if (h_addr < base_u or h_addr >= @as(usize, @intCast(self.mapped_end))) {
            @panic("kfree: backptr points outside heap");
        }

        // Alignment check
        if ((h_addr & (ALIGN_MIN - 1)) != 0) {
            @panic("kfree: header address misaligned");
        }

        const h: *Header = @ptrFromInt(h_addr);

        // Check magic number - detects corruption and double-free
        if (h.magic == FREE_MAGIC) {
            @panic("kfree: double free detected (FREE_MAGIC found)");
        }
        if (h.magic != HEADER_MAGIC) {
            if (DEBUG_CHECKS) {
                log.err("\n[KFREE] Invalid magic: 0x{x} at header 0x{x}", .{ h.magic, h_addr });
                log.err("  Expected HEADER_MAGIC: 0x{x}", .{HEADER_MAGIC});
            }
            @panic("kfree: corrupt header (bad magic)");
        }

        // Verify USED flag consistency
        if (!isUsed(h)) {
            @panic("kfree: block not marked as used (corrupt or double-free)");
        }

        // Validate header fields
        self.assertValidHeader(h, true, "kfree: header validation failed");

        // Verify footer matches header (detects buffer overruns)
        if (DEBUG_CHECKS and !verifyFooter(h)) {
            log.err("\n[KFREE] Footer mismatch at header 0x{x}", .{h_addr});
            log.err("  Header size_and_flags: 0x{x}", .{h.size_and_flags});
            log.err("  Footer value: 0x{x}", .{footerPtr(h).*});
            @panic("kfree: footer corrupted (possible buffer overrun)");
        }

        // Update statistics
        self.total_frees += 1;
        self.current_allocated_bytes -= h.user_size;

        // Poison the user data to catch use-after-free
        poisonBlock(h);

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

        self.lock.acquire();

        const old = old_ptr.?;

        const p = @intFromPtr(old);
        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;
        const h: *Header = @ptrFromInt(h_addr);

        const old_size = h.user_size;
        const copy_n = @min(new_size, old_size);

        // Lock must be free before calling kmalloc/kfree, but header info must be
        // read under the lock
        self.lock.release();

        const new_ptr = self.kmalloc(new_size, alignment) orelse return null;

        @memcpy(new_ptr[0..copy_n], old[0..copy_n]);
        self.kfree(old);
        return new_ptr;
    }

    // ========================================
    // Diagnostic Functions
    // ========================================

    /// Statistics about current heap state
    pub const HeapStats = struct {
        total_allocs: usize,
        total_frees: usize,
        current_allocated_bytes: usize,
        peak_allocated_bytes: usize,
        mapped_bytes: usize,
        free_blocks: usize,
        used_blocks: usize,
        largest_free_block: usize,
        fragmentation_percent: usize, // 0 = no fragmentation, 100 = fully fragmented
    };

    /// Get current heap statistics
    pub fn getStats(self: *KHeap) HeapStats {
        var stats = HeapStats{
            .total_allocs = self.total_allocs,
            .total_frees = self.total_frees,
            .current_allocated_bytes = self.current_allocated_bytes,
            .peak_allocated_bytes = self.peak_allocated_bytes,
            .mapped_bytes = @as(usize, @intCast(self.mapped_end - self.base)),
            .free_blocks = 0,
            .used_blocks = 0,
            .largest_free_block = 0,
            .fragmentation_percent = 0,
        };

        // Walk all blocks to count
        var total_free_bytes: usize = 0;
        var addr = @as(usize, @intCast(self.base));
        const mapped_end_u = @as(usize, @intCast(self.mapped_end));

        while (addr < mapped_end_u) {
            const h: *Header = @ptrFromInt(addr);
            const sz = blkSize(h);
            if (sz == 0 or sz > mapped_end_u - addr) break;

            if (isUsed(h)) {
                stats.used_blocks += 1;
            } else {
                stats.free_blocks += 1;
                total_free_bytes += sz;
                if (sz > stats.largest_free_block) {
                    stats.largest_free_block = sz;
                }
            }
            addr += sz;
        }

        // Fragmentation: percentage of free space that's wasted due to fragmentation
        // If we have multiple small free blocks instead of one large one, fragmentation is high
        if (stats.free_blocks > 0 and total_free_bytes > 0) {
            const ideal_free = stats.largest_free_block;
            const actual_free = total_free_bytes;
            if (actual_free > ideal_free) {
                // (1 - ideal/actual) * 100, using integer math
                stats.fragmentation_percent = 100 - (ideal_free * 100) / actual_free;
            }
        }

        return stats;
    }

    /// Comprehensive heap integrity check. Returns error details or null if healthy.
    /// Only performs full checks in debug/safe builds; always does basic checks.
    pub fn checkHeap(self: *KHeap) ?[]const u8 {
        const base_u = @as(usize, @intCast(self.base));
        const mapped_end_u = @as(usize, @intCast(self.mapped_end));

        // Basic sanity checks (always run)
        if (self.mapped_end < self.base) return "mapped_end < base";
        if (self.mapped_end > self.base + self.size) return "mapped_end exceeds heap size";

        // Walk all blocks linearly
        var addr = base_u;
        var block_count: usize = 0;
        var free_count: usize = 0;
        var used_count: usize = 0;
        var prev_was_free = false;

        while (addr < mapped_end_u) {
            const h: *Header = @ptrFromInt(addr);
            block_count += 1;

            // Check magic
            if (h.magic != HEADER_MAGIC and h.magic != FREE_MAGIC) {
                if (DEBUG_CHECKS) {
                    log.err("[checkHeap] Block {} at 0x{x}: bad magic 0x{x}", .{ block_count, addr, h.magic });
                }
                return "invalid header magic";
            }

            // Check size
            const sz = blkSize(h);
            if (sz < minBlockSize()) {
                if (DEBUG_CHECKS) {
                    log.err("[checkHeap] Block {} at 0x{x}: size {} < min {}", .{ block_count, addr, sz, minBlockSize() });
                }
                return "block size too small";
            }
            if (addr + sz > mapped_end_u) {
                if (DEBUG_CHECKS) {
                    log.err("[checkHeap] Block {} at 0x{x}: size {} exceeds mapped region", .{ block_count, addr, sz });
                }
                return "block extends past mapped region";
            }

            // Check alignment
            if ((sz & (ALIGN_MIN - 1)) != 0) {
                return "block size not aligned";
            }

            // Check footer matches header
            if (DEBUG_CHECKS) {
                if (!verifyFooter(h)) {
                    log.err("[checkHeap] Block {} at 0x{x}: footer mismatch", .{ block_count, addr });
                    return "footer mismatch (possible overrun)";
                }
            }

            // Check magic vs used flag consistency
            const used = isUsed(h);
            if (used and h.magic != HEADER_MAGIC) return "used block has wrong magic";
            if (!used and h.magic != FREE_MAGIC) return "free block has wrong magic";

            // Check for adjacent free blocks (should have been coalesced)
            if (DEBUG_CHECKS) {
                if (!used and prev_was_free) {
                    log.err("[checkHeap] Block {} at 0x{x}: adjacent free blocks not coalesced", .{ block_count, addr });
                    return "adjacent free blocks (coalesce bug)";
                }
            }

            if (used) {
                used_count += 1;
            } else {
                free_count += 1;
            }
            prev_was_free = !used;

            addr += sz;
        }

        // Verify we ended exactly at mapped_end
        if (addr != mapped_end_u) {
            if (DEBUG_CHECKS) {
                log.err("[checkHeap] Block walk ended at 0x{x}, expected 0x{x}", .{ addr, mapped_end_u });
            }
            return "block sizes don't sum to mapped region";
        }

        // Verify free list integrity
        if (DEBUG_CHECKS) {
            var list_free_count: usize = 0;
            for (0..BIN_COUNT) |bin| {
                var cur = self.bins[bin];
                var list_len: usize = 0;
                while (cur) |node| {
                    list_len += 1;
                    list_free_count += 1;

                    // Verify node is free
                    if (isUsed(node)) return "used block in free list";
                    if (node.magic != FREE_MAGIC) return "bad magic in free list";

                    // Verify node is in correct bin
                    const expected_bin = binIndex(blkSize(node));
                    if (expected_bin != bin) {
                        log.err("[checkHeap] Block in bin {} should be in bin {}", .{ bin, expected_bin });
                        return "block in wrong bin";
                    }

                    // Verify doubly-linked list integrity
                    if (node.prev_free) |prev| {
                        if (prev.next_free != node) return "free list prev->next != node";
                    }
                    if (node.next_free) |nxt| {
                        if (nxt.prev_free != node) return "free list next->prev != node";
                    }

                    // Detect cycles (simple check: limit iterations)
                    if (list_len > 100000) return "free list too long (cycle?)";

                    cur = node.next_free;
                }
            }

            // Free list count should match block walk count
            if (list_free_count != free_count) {
                log.err("[checkHeap] Free list has {} blocks, walk found {}", .{ list_free_count, free_count });
                return "free list count mismatch";
            }
        }

        // Verify wilderness
        if (@intFromPtr(self.wilderness) < base_u or @intFromPtr(self.wilderness) >= mapped_end_u) {
            return "wilderness pointer out of bounds";
        }

        return null; // Heap is healthy
    }

    /// Print heap diagnostics to serial console
    pub fn dumpStats(self: *KHeap) void {
        const stats = self.getStats();

        log.debug("\n=== Heap Statistics ===", .{});
        log.debug("\tBase: 0x{x}, Mapped: {} KB / {} MB", .{
            self.base,
            stats.mapped_bytes / 1024,
            self.size / (1024 * 1024),
        });
        log.debug("\tAllocations: {} total, {} frees", .{ stats.total_allocs, stats.total_frees });
        log.debug("\tCurrent: {} bytes, Peak: {} bytes", .{ stats.current_allocated_bytes, stats.peak_allocated_bytes });
        log.debug("\tBlocks: {} used, {} free", .{ stats.used_blocks, stats.free_blocks });
        log.debug("\tLargest free: {} bytes", .{stats.largest_free_block});
        log.debug("\tFragmentation: {}%", .{stats.fragmentation_percent});

        if (self.checkHeap()) |err| {
            log.debug("\tINTEGRITY: FAILED - {s}", .{err});
        } else {
            log.debug("\tIntegrity: OK", .{});
        }
    }

    /// Get a std.mem.Allocator interface for this heap
    pub fn allocator(self: *KHeap) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocImpl,
                .resize = resizeImpl,
                .free = freeImpl,
                .remap = remapImpl,
            },
        };
    }

    fn allocImpl(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *KHeap = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @as(std.math.Log2Int(usize), @intFromEnum(ptr_align));
        return self.kmalloc(len, alignment);
    }

    fn resizeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = buf_align;
        _ = ret_addr;

        const self: *KHeap = @ptrCast(@alignCast(ctx));
        _ = self;

        const p = @intFromPtr(buf.ptr);
        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;
        const h: *Header = @ptrFromInt(h_addr);

        const current_size = h.user_size;
        if (new_len <= current_size) {
            h.user_size = new_len;
            return true;
        }

        const payload_start = @intFromPtr(h) + @sizeOf(Header);
        const with_backptr = payload_start + BACKPTR_SIZE;
        const user_ptr = @intFromPtr(buf.ptr);
        const padding = user_ptr - with_backptr;
        const available_payload = blkSize(h) - @sizeOf(Header) - @sizeOf(usize) - padding;

        if (new_len <= available_payload) {
            h.user_size = new_len;
            return true;
        }

        return false;
    }

    fn freeImpl(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;
        const self: *KHeap = @ptrCast(@alignCast(ctx));
        self.kfree(buf.ptr);
    }
    fn remapImpl(
        ctx: *anyopaque,
        buf: []u8,
        buf_align: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        _ = ret_addr;
        const self: *KHeap = @ptrCast(@alignCast(ctx));

        // Get the header for this allocation
        const p = @intFromPtr(buf.ptr);
        const backptr_addr = p - BACKPTR_SIZE;
        const h_addr = @as(*usize, @ptrFromInt(backptr_addr)).*;
        const h: *Header = @ptrFromInt(h_addr);

        const alignment = @as(usize, 1) << @intFromEnum(buf_align);

        // Check if we can resize in place
        const current_size = h.user_size;
        if (new_len <= current_size) {
            // Shrinking - always succeeds
            h.user_size = new_len;
            return buf.ptr;
        }

        // Growing - check if we have room in this block
        const payload_start = @intFromPtr(h) + @sizeOf(Header);
        const with_backptr = payload_start + BACKPTR_SIZE;
        const user_ptr = @intFromPtr(buf.ptr);
        const padding = user_ptr - with_backptr;
        const available_payload = blkSize(h) - @sizeOf(Header) - @sizeOf(usize) - padding;

        if (new_len <= available_payload) {
            h.user_size = new_len;
            return buf.ptr;
        }

        // Can't resize in place - allocate new memory with same alignment
        const new_ptr = self.kmalloc(new_len, alignment) orelse return null;

        // Copy old data
        @memcpy(new_ptr[0..current_size], buf.ptr[0..current_size]);

        // Free old allocation
        self.kfree(buf.ptr);

        return new_ptr;
    }
};
