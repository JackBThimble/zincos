const std = @import("std");
const process = @import("process/mod.zig");
const mm = @import("mm");

pub const ShmId = u32;
const PAGE_SIZE: u64 = mm.PAGE_SIZE;

const Segment = struct {
    owner_pid: process.ProcessId,
    page_count: usize,
    frames: []u64,
    allowed: std.AutoHashMapUnmanaged(process.ProcessId, void) = .{},
    mappings: std.AutoHashMapUnmanaged(MappingKey, void) = .{},

    fn deinit(self: *Segment, allocator: std.mem.Allocator) void {
        for (self.frames) |phys| {
            mm.address_space.freePhysFrame(phys);
        }
        allocator.free(self.frames);
        self.allowed.deinit(allocator);
        self.mappings.deinit(allocator);
    }
};

const MappingKey = struct {
    pid: process.ProcessId,
    virt: u64,
};

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

var global_allocator: ?std.mem.Allocator = null;
var lock: SpinLock = .{};
var next_id: ShmId = 1;
var segments: std.AutoHashMapUnmanaged(ShmId, *Segment) = .{};

pub fn init(allocator: std.mem.Allocator) void {
    lock.acquire();
    defer lock.release();

    if (global_allocator) |existing| {
        var it = segments.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(existing);
            existing.destroy(entry.value_ptr.*);
        }
        segments.deinit(existing);
    }

    global_allocator = allocator;
    segments = .{};
    next_id = 1;
}

pub fn create(owner_pid: process.ProcessId, size_bytes: usize) !ShmId {
    if (size_bytes == 0) return error.InvalidSize;
    const allocator = global_allocator orelse return error.NotInitialized;

    const pages_u64 = std.math.divCeil(u64, @as(u64, size_bytes), PAGE_SIZE) catch return error.InvalidSize;
    const page_count: usize = std.math.cast(usize, pages_u64) orelse return error.InvalidSize;

    const seg = try allocator.create(Segment);
    errdefer allocator.destroy(seg);

    const frames = try allocator.alloc(u64, page_count);
    errdefer allocator.free(frames);

    for (0..page_count) |i| {
        const phys = mm.address_space.allocPhysFrame() orelse {
            for (frames[0..i]) |f| mm.address_space.freePhysFrame(f);
            return error.OutOfMemory;
        };
        mm.address_space.zeroPhysFrame(phys);
        frames[i] = phys;
    }

    seg.* = .{
        .owner_pid = owner_pid,
        .page_count = page_count,
        .frames = frames,
    };

    try seg.allowed.put(allocator, owner_pid, {});

    lock.acquire();
    defer lock.release();

    const id = next_id;
    next_id +%= 1;
    if (id == 0) return error.OutOfIds;

    try segments.put(allocator, id, seg);
    return id;
}

fn getSegment(id: ShmId) ?*Segment {
    return segments.get(id);
}

pub fn grant(id: ShmId, owner_pid: process.ProcessId, target_pid: process.ProcessId) !void {
    const allocator = global_allocator orelse return error.NotInitialized;

    lock.acquire();
    defer lock.release();

    const seg = getSegment(id) orelse return error.InvalidSegment;
    if (seg.owner_pid != owner_pid) return error.PermissionDenied;

    try seg.allowed.put(allocator, target_pid, {});
}

pub fn mapCurrent(id: ShmId, pid: process.ProcessId, as: *mm.address_space.AddressSpace, virt_base: u64) !void {
    if (!std.mem.isAligned(virt_base, PAGE_SIZE)) return error.UnalignedAddress;

    lock.acquire();
    defer lock.release();

    const seg = getSegment(id) orelse return error.InvalidSegment;
    if (!seg.allowed.contains(pid)) return error.PermissionDenied;

    const key = MappingKey{ .pid = pid, .virt = virt_base };
    if (seg.mappings.contains(key)) return error.AlreadyMapped;

    var mapped: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < mapped) : (i += 1) {
            _ = as.unmapPage(virt_base + @as(u64, @intCast(i)) * PAGE_SIZE);
        }
    }

    for (seg.frames, 0..) |phys, i| {
        const virt = virt_base + @as(u64, @intCast(i)) * PAGE_SIZE;
        try as.mapPage(virt, phys, mm.vmm.MapFlags.user_data);
        mapped += 1;
    }

    try seg.mappings.put(global_allocator.?, key, {});
}

pub fn unmapCurrent(id: ShmId, pid: process.ProcessId, as: *mm.address_space.AddressSpace, virt_base: u64) !void {
    if (!std.mem.isAligned(virt_base, PAGE_SIZE)) return error.UnalignedAddress;

    lock.acquire();
    defer lock.release();

    const seg = getSegment(id) orelse return error.InvalidSegment;
    const key = MappingKey{ .pid = pid, .virt = virt_base };
    if (!seg.mappings.contains(key)) return error.NotMapped;

    for (seg.frames, 0..) |phys, i| {
        const virt = virt_base + @as(u64, @intCast(i)) * PAGE_SIZE;
        const old = as.unmapPage(virt) orelse return error.NotMapped;
        if (old != phys) return error.MappingCorrupted;
    }

    _ = seg.mappings.remove(key);
}

pub fn destroy(id: ShmId, caller_pid: process.ProcessId) !void {
    const allocator = global_allocator orelse return error.NotInitialized;

    lock.acquire();
    defer lock.release();

    const seg = getSegment(id) orelse return error.InvalidSegment;
    if (seg.owner_pid != caller_pid) return error.PermissionDenied;
    if (seg.mappings.count() != 0) return error.Busy;

    const removed = segments.fetchRemove(id) orelse return error.InvalidSegment;
    removed.value.deinit(allocator);
    allocator.destroy(removed.value);
}
