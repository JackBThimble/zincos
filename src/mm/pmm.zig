const std = @import("std");
const arch = @import("arch");
const shared = @import("shared");
const log = shared.log;
const BootInfo = shared.boot.BootInfo;
const MemoryRegion = shared.boot.MemoryRegion;
const MemoryKind = shared.boot.MemoryKind;
const FramebufferInfo = shared.boot.FramebufferInfo;
const MAX_CPUS = shared.types.MAX_CPUS;

pub const PAGE_SIZE: u64 = 4096;
pub const PhysRange = struct { base: u64, len: u64 };

// ----------------------
// Per-CPU page cache
// ----------------------
const CACHE_SIZE = 64;
const REFILL_COUNT = 32;
const FLUSH_THRESHOLD = 56;

const PcpuCache = struct {
    frames: [CACHE_SIZE]u64 = [_]u64{0} ** CACHE_SIZE,
    count: u32 = 0,

    /// Fast path: pop a frame, no lock neccessary
    fn pop(self: *PcpuCache) ?u64 {
        if (self.count == 0) return null;
        self.count -= 1;
        return self.frames[self.count];
    }

    /// Fast path: push a frame, no lock neccessary
    /// Returns false if full (caller should flush to global to first)
    fn push(self: *PcpuCache, frame: u64) bool {
        if (self.count >= CACHE_SIZE) return false;
        self.frames[self.count] = frame;
        self.count += 1;
        return true;
    }

    /// Drain n frames out for flushing back to global
    fn drainBatch(self: *PcpuCache, out: []u64) u32 {
        const n: u32 = @intCast(@min(out.len, self.count));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.count -= 1;
            out[i] = self.frames[self.count];
        }
        return n;
    }
};

// ------------------------------
// Global lock
// ------------------------------
const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

pub const FrameAllocator = struct {
    hhdm_base: u64,
    bitmap_phys: u64,
    bitmap: []volatile u8,
    frame_count: usize,
    used_frames: usize,
    lock: SpinLock = .{},
    pcpu: [MAX_CPUS]PcpuCache = [_]PcpuCache{.{}} ** MAX_CPUS,

    pub fn init(self: *FrameAllocator, bi: *const BootInfo) void {
        const regions = memoryMapSlice(bi);
        const max_phys = maxPhysEnd(regions);
        const frame_count: usize = @intCast((max_phys + PAGE_SIZE - 1) / PAGE_SIZE);
        const bitmap_bytes: usize = (frame_count + 7) / 8;

        const bi_virt = @intFromPtr(bi);
        const bi_phys = bi_virt - bi.hhdm_base;
        const memmap_bytes = bi.memory_map_entries * @sizeOf(MemoryRegion);

        // Build a reserve list
        var reserve_fixed = [_]PhysRange{
            // Reserve first 1MB for BIOS/UEFI data area
            .{ .base = 0, .len = 0x100000 },
            .{ .base = bi.kernel_physical_base, .len = bi.kernel_size },
            .{ .base = bi.framebuffer.base_address, .len = framebufferByteSize(&bi.framebuffer) },
            .{ .base = bi_phys, .len = @sizeOf(BootInfo) },
            .{ .base = bi.memory_map_addr, .len = memmap_bytes },
        };

        const placement = findBitmapPlacement(regions, bitmap_bytes, &reserve_fixed) orelse @panic("no usable memory for bitmap");

        const bitmap_phys = placement;
        const bitmap_virt = bi.hhdm_base + bitmap_phys;

        const bitmap_ptr: [*]volatile u8 = @ptrFromInt(@as(usize, @intCast(bitmap_virt)));
        const bitmap = bitmap_ptr[0..bitmap_bytes];

        const tail_bits = (bitmap_bytes * 8) - frame_count;
        if (tail_bits != 0) {
            const valid_bits: u8 = @intCast(8 - tail_bits);
            const shift: u3 = @intCast(valid_bits);
            const mask: u8 = @as(u8, 0xff) << shift;
            bitmap[bitmap_bytes - 1] |= mask;
        }

        memsetVolatile(bitmap, 0xff);

        self.* = .{
            .hhdm_base = bi.hhdm_base,
            .bitmap_phys = bitmap_phys,
            .bitmap = bitmap,
            .frame_count = frame_count,
            .used_frames = frame_count,
        };

        for (regions) |r| {
            if (r.kind != .usable and r.kind != .bootloader_reclaimable) continue;
            self.markRangeFree(r.base, r.length);
        }

        self.markRangeUsed(bitmap_phys, bitmap_bytes);

        for (reserve_fixed) |rr| {
            self.markRangeUsed(rr.base, rr.len);
        }
    }

    pub fn allocFrame(self: *FrameAllocator) ?u64 {
        const cpu_id = arch.getCpuId();
        var cache = &self.pcpu[cpu_id];

        if (cache.pop()) |frame| return frame;

        self.lock.acquire();
        defer self.lock.release();

        var refilled: u32 = 0;
        while (refilled < REFILL_COUNT) : (refilled += 1) {
            const frame = self.bitmapAlloc() orelse break;
            _ = cache.push(frame);
        }

        return cache.pop();
    }

    pub fn freeFrame(self: *FrameAllocator, phys: u64) void {
        std.debug.assert((phys & (PAGE_SIZE - 1)) == 0);
        assertPhys(phys);

        const cpu_id = arch.getCpuId();
        var cache = &self.pcpu[cpu_id];

        if (cache.push(phys)) {
            if (cache.count >= FLUSH_THRESHOLD) {
                self.flushToGlobal(cache);
            }
            return;
        }
        self.flushToGlobal(cache);
        _ = cache.push(phys);
    }

    fn bitmapAlloc(self: *FrameAllocator) ?u64 {
        for (self.bitmap, 0..) |b, byte_i| {
            if (b == 0xff) continue;

            // find first 0 bit
            var mask: u8 = 1;
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                if ((b & mask) == 0) {
                    const frame_index = byte_i * 8 + bit;
                    if (frame_index >= self.frame_count) return null;

                    self.bitmap[byte_i] = b | mask;
                    self.used_frames += 1;
                    return @as(u64, @intCast(frame_index)) * PAGE_SIZE;
                }
                mask <<= 1;
            }
        }
        return null;
    }

    fn bitmapFree(self: *FrameAllocator, phys: u64) void {
        const frame_index: usize = @intCast(phys / PAGE_SIZE);
        const byte_i = frame_index / 8;
        const bit_i: u3 = @intCast(frame_index % 8);
        const mask: u8 = @as(u8, 1) << bit_i;

        if (frame_index >= self.frame_count) {
            log.err("PMM Error: Attempted to free frame outside of range", .{});
            return;
        }
        if ((self.bitmap[byte_i] & mask) == 0) @panic("double free frame");
        self.bitmap[byte_i] &= ~mask;
        self.used_frames -= 1;
    }

    fn flushToGlobal(self: *FrameAllocator, cache: *PcpuCache) void {
        const half = cache.count / 2;
        if (half == 0) return;

        var batch: [CACHE_SIZE / 2]u64 = undefined;
        const n = cache.drainBatch(batch[0..half]);

        self.lock.acquire();
        defer self.lock.release();

        for (0..n) |i| {
            self.bitmapFree(batch[i]);
        }
    }

    fn markRangeFree(self: *FrameAllocator, base: u64, len: u64) void {
        var p = std.mem.alignBackward(u64, base, PAGE_SIZE);
        const end = std.mem.alignForward(u64, base + len, PAGE_SIZE);
        while (p < end) : (p += PAGE_SIZE) self.markFree(p);
    }

    fn markRangeUsed(self: *FrameAllocator, base: u64, len: u64) void {
        var p = std.mem.alignBackward(u64, base, PAGE_SIZE);
        const end = std.mem.alignForward(u64, base + len, PAGE_SIZE);
        while (p < end) : (p += PAGE_SIZE) self.markUsed(p);
    }

    fn markFree(self: *FrameAllocator, phys: u64) void {
        const i: usize = @intCast(phys / PAGE_SIZE);
        const byte_i = i / 8;
        const bit_i: u3 = @intCast(i % 8);
        const mask: u8 = @as(u8, 1) << bit_i;

        if (i >= self.frame_count) {
            log.err("PMM Error: Attempted to free frame outside of range", .{});
            return;
        }
        if ((self.bitmap[byte_i] & mask) != 0) {
            self.bitmap[byte_i] &= ~mask;
            self.used_frames -= 1;
        }
    }

    fn markUsed(self: *FrameAllocator, phys: u64) void {
        assertPhys(phys);
        const i: usize = @intCast(phys / PAGE_SIZE);
        const byte_i = i / 8;
        const bit_i: u3 = @intCast(i % 8);
        const mask: u8 = @as(u8, 1) << bit_i;

        if (i >= self.frame_count) {
            log.err("PMM Error:Attempted to mark used frame outside of range", .{});
            return;
        }
        if ((self.bitmap[byte_i] & mask) == 0) {
            self.bitmap[byte_i] |= mask;
            self.used_frames += 1;
        }
    }
};

fn assertPhys(phys: u64) void {
    if ((phys >> 48) != 0) @panic("non-physical address passed to frame allocator");
}

fn memoryMapSlice(bi: *const BootInfo) []const MemoryRegion {
    const ptr = bi.hhdm_base + bi.memory_map_addr;
    const base: [*]const MemoryRegion = @ptrFromInt(@as(usize, @intCast(ptr)));
    return base[0..@as(usize, @intCast(bi.memory_map_entries))];
}

fn maxPhysEnd(regions: []const MemoryRegion) u64 {
    var m: u64 = 0;
    for (regions) |r| m = @max(m, r.base + r.length);
    return m;
}

fn framebufferByteSize(fb: *const FramebufferInfo) u64 {
    return @as(u64, fb.pitch) * @as(u64, fb.height);
}

fn overlaps(a: PhysRange, b: PhysRange) bool {
    const a_end = a.base + a.len;
    const b_end = b.base + b.len;
    return !(a_end <= b.base or b_end <= a.base);
}

fn findBitmapPlacement(
    regions: []const MemoryRegion,
    bytes: usize,
    reserves: []const PhysRange,
) ?u64 {
    const need = std.mem.alignForward(u64, @as(u64, @intCast(bytes)), PAGE_SIZE);

    for (regions) |r| {
        if (r.kind != .usable) continue;

        var base = std.mem.alignForward(u64, r.base, PAGE_SIZE);
        const end = r.base + r.length;

        while (base + need <= end) : (base += PAGE_SIZE) {
            const candidate = PhysRange{ .base = base, .len = need };

            var ok = true;
            for (reserves) |rr| {
                if (overlaps(candidate, rr)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return base;
        }
    }
    return null;
}

fn memsetVolatile(buf: []volatile u8, v: u8) void {
    for (buf) |*b| b.* = v;
}
