const std = @import("std");
const serial = @import("arch").serial;
const kalloc = @import("kalloc.zig");

const SlotCount = 2048;
const MaxSize = 8192;

const Slot = struct {
    ptr: ?[*]u8 = null,
    size: usize = 0,
    alignment: usize = 0,
    tag: u64 = 0,
};

pub fn run(ka: *kalloc.KAlloc, iters: usize) void {
    serial.printfln("kalloc stress: slots={d}  iters={d}", .{ SlotCount, iters });
    var slots = std.mem.zeroes([SlotCount]Slot);

    var rng = XorShift64.init(0xc0ffee_baad_f00d);

    var live_bytes: usize = 0;
    var max_live_bytes: usize = 0;
    var alloc_ok: usize = 0;
    var alloc_fail: usize = 0;
    var free_ok: usize = 0;
    var verify_fail: usize = 0;

    // Bias: mostly alloc early, then mixed
    for (0..iters) |i| {
        const idx: usize = @intCast(rng.next() % SlotCount);

        const do_alloc = if (slots[idx].ptr == null)
            true
        else
            (rng.next() & 3) != 0;

        if (do_alloc) {
            // Sometimes allocate into an empty slot; sometimes overwrite by freeing first
            if (slots[idx].ptr != null) {
                // verify then free
                if (!verify(slots[idx])) {
                    verify_fail += 1;
                    dumpSlot("verify_fail_before_overwrite", slots[idx]);
                    @panic("kalloc stress: corruption detected");
                }
                ka.free(slots[idx].ptr);
                live_bytes -= slots[idx].size;
                free_ok += 1;
                slots[idx] = .{};
            }

            const size = pickSize(&rng);
            const alignment = pickAlign(&rng, size);

            const p = ka.kmallocAligned(size, alignment);
            if (p == null) {
                alloc_fail += 1;
                // keep going:failures are allowed if heap ceiling is hit
                continue;
            }

            const tag = rng.next();
            slots[idx] = .{ .ptr = p, .size = size, .alignment = alignment, .tag = tag };

            if ((@intFromPtr(p.?) & (alignment - 1)) != 0) {
                dumpSlot("bad_alignment", slots[idx]);
                @panic("kalloc stress: alignment broken");
            }

            poison(slots[idx]); // write pattern
            live_bytes += size;
            if (live_bytes > max_live_bytes) max_live_bytes = live_bytes;
            alloc_ok += 1;
        } else {
            // free path
            if (slots[idx].ptr) |_| {
                if (!verify(slots[idx])) {
                    verify_fail += 1;
                    dumpSlot("verify_fail_before_free", slots[idx]);
                    @panic("kalloc stress: corruption detected");
                }
                ka.free(slots[idx].ptr);
                live_bytes -= slots[idx].size;
                free_ok += 1;
                slots[idx] = .{};
            }
        }

        // Occasionally do a full sweep to force coalescing patterns
        if ((i % 5000) == 0 and i != 0) {
            serial.printfln("  sweep @{} live={} max_live={} ok={} fail={}", .{
                i, live_bytes, max_live_bytes, alloc_ok, alloc_fail,
            });
            sweep(ka, &slots, &live_bytes);
        }
    }

    sweep(ka, &slots, &live_bytes);

    serial.printfln("kalloc stress done:", .{});
    serial.printfln("    alloc_ok={} alloc_fail={}", .{ alloc_ok, alloc_fail });
    serial.printfln("    free_ok={} verify_fail={}", .{ free_ok, verify_fail });
    serial.printfln("    max_live_bytes={}", .{max_live_bytes});
}

fn sweep(ka: *kalloc.KAlloc, slots: *[SlotCount]Slot, live_bytes: *usize) void {
    for (slots) |*s| {
        if (s.ptr) |_| {
            if (!verify(s.*)) {
                dumpSlot("verify_fail_in_sweep", s.*);
                @panic("kalloc stress: corruption detected");
            }
            ka.free(s.ptr);
            live_bytes.* -= s.size;
            s.* = .{};
        }
    }
}

fn dumpSlot(reason: []const u8, s: Slot) void {
    serial.printfln("SLOT DUMP: {s}", .{reason});
    serial.printfln("    ptr=0x{x} size={} align={} tag=0x{x}", .{
        @intFromPtr(s.ptr.?),
        s.size,
        s.alignment,
        s.tag,
    });
}

fn pickSize(rng: *XorShift64) usize {
    // Skew towards small allocations but include some bigger ones
    const r = rng.next();
    const bucket = r & 0xff;

    if (bucket < 160) return @intCast(1 + (r % 256));
    if (bucket < 220) return @intCast(257 + (r % 1024));
    if (bucket < 245) return @intCast(1281 + (r % 4096));
    const upper = if (MaxSize > 5377) MaxSize - 5377 + 1 else 1;
    return 5377 + (r % upper);
}

fn pickAlign(rng: *XorShift64, size: usize) usize {
    // Alignment: 16, 32, 64, 256, 4096 sometimes.
    // Never ask for align > size unless size is tiny; allocator should handle either way
    //  but keep it reasonable.
    const r = rng.next() & 7;
    const a: usize = switch (r) {
        0 => 16,
        1 => 32,
        2 => 64,
        3 => 256,
        4 => 4096,
        else => 16,
    };
    // If size is tiny, still allow big align occasionally (this tests prefix-split/backptr logic).
    _ = size;
    return a;
}

fn poison(s: Slot) void {
    const p = s.ptr.?;

    for (0..s.size) |i| {
        p[i] = patternByte(s.tag, i);
    }

    // put "sentinel" u64s at start and end
    if (s.size >= 16) {
        const head: *volatile u64 = @ptrCast(@alignCast(p));
        head.* = s.tag ^ 0x1111_2222_3333_4444;

        const tail_addr = @intFromPtr(p) + s.size - 8;
        const tail: *volatile u64 = @ptrFromInt(@as(usize, @intCast(tail_addr)));
        tail.* = s.tag ^ 0xaaaa_bbbb_cccc_dddd;
    }
}

fn verify(s: Slot) bool {
    const p = s.ptr.?;

    if (s.size >= 16) {
        const head: *const volatile u64 = @ptrCast(@alignCast(p));
        if (head.* != (s.tag ^ 0x1111_2222_3333_4444)) return false;

        const tail_addr = @intFromPtr(p) + s.size - 8;
        const tail: *const volatile u64 = @ptrFromInt(@as(usize, @intCast(tail_addr)));
        if (tail.* != (s.tag ^ 0xaaaa_bbbb_cccc_dddd)) return false;
    }

    // spot-check a handful of bytes (faster than full scan)
    const checks: [8]usize = .{ 0, 1, 2, 3, s.size / 2, s.size - 4, s.size - 2, s.size - 1 };
    for (checks) |idx| {
        if (idx >= s.size) continue;
        if (p[idx] != patternByte(s.tag, idx)) return false;
    }
    return true;
}

fn patternByte(tag: u64, i: usize) u8 {
    const mul = @as(u64, @intCast(i)) *% 0x9e37_79b9_7f4a_7c15;
    const x = tag ^ mul;
    return @truncate(x ^ (x >> 8) ^ (x >> 16) ^ (x >> 24));
}

// Deterministic PRNG
const XorShift64 = struct {
    state: u64,

    pub fn init(seed: u64) XorShift64 {
        return .{ .state = if (seed != 0) seed else 0x1234_5678_9abc_def0 };
    }

    pub fn next(self: *XorShift64) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }
};
