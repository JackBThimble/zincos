const std = @import("std");
const heap_mod = @import("heap.zig");

const BACKPTR_SIZE = @sizeOf(usize);
const MIN_ALIGN: usize = 16;
const MIN_SPLIT: usize = @sizeOf(Block) + MIN_ALIGN;

fn layout(
    block_addr: usize,
    block_size: usize,
    size: usize,
    alignment: usize,
) ?struct {
    user_addr: usize,
    alloc_total: usize,
    prefix: usize,
} {
    const user_base = block_addr + @sizeOf(Block) + BACKPTR_SIZE;
    const user_addr = alignUp(user_base, alignment);

    const alloc_end = user_addr + size;
    const alloc_total = alloc_end - block_addr;

    if (alloc_total > block_size) return null;

    const alloc_start = user_addr - BACKPTR_SIZE - @sizeOf(Block);
    const prefix = alloc_start - block_addr;

    return .{
        .user_addr = user_addr,
        .alloc_total = alloc_total,
        .prefix = prefix,
    };
}

pub const KAlloc = struct {
    heap: *heap_mod.Heap,
    free_list: ?*Block = null,

    pub fn init(heap: *heap_mod.Heap) KAlloc {
        return .{
            .heap = heap,
            .free_list = null,
        };
    }

    /// Allocate `size` bytes with `alignment` alignment (power of two).
    pub fn alloc(self: *KAlloc, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;
        if (!std.math.isPowerOfTwo(alignment)) return null;

        const min_align = @max(alignment, MIN_ALIGN);

        var prev: ?*Block = null;
        var cur = self.free_list;

        while (cur) |blk_const| : (cur = blk_const.next) {
            var blk = blk_const; // mutable working pointer
            if (!blk.is_free) @panic("free list corrupted");

            const blk_addr = @intFromPtr(blk);

            const lay = layout(blk_addr, blk.size, size, min_align) orelse {
                prev = blk;
                continue;
            };

            removeFromFreeList(&self.free_list, prev, blk);

            if (lay.prefix >= MIN_SPLIT) {
                const prefix_blk: *Block = blk;
                prefix_blk.* = Block{
                    .size = lay.prefix,
                    .is_free = true,
                    .next = null,
                };
                self.freeInsert(prefix_blk);

                blk = @ptrFromInt(blk_addr + lay.prefix);

                blk.size -= lay.prefix;
            }

            // tail split
            const tail = blk.size - lay.alloc_total;
            if (tail >= MIN_SPLIT) {
                const tail_blk: *Block = @ptrFromInt(blk_addr + lay.alloc_total);

                tail_blk.* = Block{
                    .size = tail,
                    .is_free = true,
                    .next = null,
                };
                self.freeInsert(tail_blk);
                blk.size = lay.alloc_total;
            }

            blk.is_free = false;
            blk.next = null;

            const user_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(lay.user_addr)));

            storeBackPointer(user_ptr, blk);
            std.debug.assert((@intFromPtr(user_ptr) & (min_align - 1)) == 0);

            return user_ptr;
        }

        // Heap grow path
        const request = @sizeOf(Block) + BACKPTR_SIZE + size + (min_align - 1);

        const raw = self.heap.alloc(request, MIN_ALIGN) orelse return null;
        const raw_addr = @intFromPtr(raw);

        var blk: *Block = @ptrFromInt(raw_addr);
        blk.* = Block{
            .size = request,
            .is_free = false,
            .next = null,
        };

        const lay = layout(raw_addr, request, size, min_align) orelse @panic("[KALLOC:ERROR]: heap layout failed");

        // prefix split
        if (lay.prefix >= MIN_SPLIT) {
            const prefix_blk: *Block = blk;
            prefix_blk.* = Block{
                .size = lay.prefix,
                .is_free = true,
                .next = null,
            };

            self.freeInsert(prefix_blk);

            blk = @ptrFromInt(raw_addr + lay.prefix);
            blk.size -= lay.prefix;
            blk.is_free = false;
        }

        const user_ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(lay.user_addr)));

        storeBackPointer(user_ptr, blk);
        std.debug.assert((@intFromPtr(user_ptr) & (min_align - 1)) == 0);

        return user_ptr;
    }

    pub fn free(self: *KAlloc, ptr: ?[*]u8) void {
        if (ptr == null) return;

        const p = ptr.?;
        const user_addr = @intFromPtr(p);

        // Header is somewhere before user_addr, but user may be aligned forward.
        // Need a reliable way to find it.
        // This allocator ensures:
        //  - user pointer return is >= (block_addr + sizeof(Block))
        //  - but could be advanced by alignment
        // The block header is stored at the start of the block, so it must be located
        // by scanning backwards from user_addr.
        // To avoid scanning, a back-pointer is stored just before user.
        // Storing the back-pointer at (user_ptr - 8).
        const hdr_ptr_addr = user_addr - @sizeOf(usize);
        const hdr_ptr: *const usize = @ptrFromInt(@as(usize, @intCast(hdr_ptr_addr)));
        const blk_addr = hdr_ptr.*;
        const blk: *Block = @ptrFromInt(blk_addr);

        if (blk.is_free) @panic("[KAlloc:Error]: double free");
        blk.is_free = true;

        self.freeInsert(blk);
        self.coalesceAround(blk);
    }

    /// Convenience wrappers
    pub fn kmalloc(self: *KAlloc, size: usize) ?[*]u8 {
        return self.alloc(size, MIN_ALIGN);
    }

    pub fn kmallocAligned(self: *KAlloc, size: usize, alignment: usize) ?[*]u8 {
        return self.alloc(size, alignment);
    }

    // --------------------------------
    // Internals
    // --------------------------------
    fn freeInsert(self: *KAlloc, blk: *Block) void {
        // Insert sorted by address (needed for coalescing).
        var prev: ?*Block = null;
        var cur = self.free_list;

        const blk_addr = @intFromPtr(blk);

        while (cur) |c| : (cur = c.next) {
            if (@intFromPtr(c) > blk_addr) break;
            prev = c;
        }

        if (prev) |p| {
            blk.next = p.next;
            p.next = blk;
        } else {
            blk.next = self.free_list;
            self.free_list = blk;
        }
    }

    fn coalesceAround(self: *KAlloc, blk: *Block) void {
        // Coalesce with next if adjacent.
        if (blk.next) |n| {
            const end = @intFromPtr(blk) + blk.size;
            if (end == @intFromPtr(n) and n.is_free) {
                blk.size += n.size;
                blk.next = n.next;
            }
        }

        // Coalesce with prev if adjacent: need to search for previous block
        var prev: ?*Block = null;
        var cur = self.free_list;
        while (cur) |c| : (cur = c.next) {
            if (c == blk) break;
            prev = c;
        }
        if (prev) |p| {
            const pend = @intFromPtr(p) + p.size;
            if (pend == @intFromPtr(blk) and p.is_free) {
                p.size += blk.size;
                p.next = blk.next;
            }
        }
    }
};

const Block = packed struct {
    // Total size of this block in bytes, including header and user/padding.
    size: usize,
    is_free: bool,
    // padding for alignment; NOTE: Can use extern instead of packed
    next: ?*Block,
};

fn removeFromFreeList(head: *?*Block, prev: ?*Block, cur: *Block) void {
    if (prev) |p| {
        p.next = cur.next;
    } else {
        head.* = cur.next;
    }
    cur.next = null;
}

fn alignUp(x: usize, a: usize) usize {
    return (x +% (a - 1)) & ~(a - 1);
}

fn storeBackPointer(user: [*]u8, blk: *Block) void {
    const user_addr = @intFromPtr(user);
    const slot_addr = user_addr - @sizeOf(usize);
    const slot: *usize = @ptrFromInt(@as(usize, @intCast(slot_addr)));
    slot.* = @intFromPtr(blk);
}
