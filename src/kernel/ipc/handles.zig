const std = @import("std");
const process = @import("../process/mod.zig");
const sched = @import("../sched/mod.zig");
const registry = @import("registry.zig");
const Task = @import("../sched/task.zig").Task;
const EndpointId = registry.EndpointId;

pub const Handle = u32;

const MAX_SLOTS: usize = 16 * 1024;
const INDEX_BITS: u5 = 14;
const GEN_BITS: u5 = 12;
const KIND_BITS: u5 = 2;
const RIGHTS_BITS: u5 = 4;

const INDEX_MASK: u32 = (1 << INDEX_BITS) - 1;
const GEN_MASK: u32 = (1 << GEN_BITS) - 1;
const KIND_MASK: u32 = (1 << KIND_BITS) - 1;
const RIGHTS_MASK: u32 = (1 << RIGHTS_BITS) - 1;

const GEN_SHIFT: u5 = INDEX_BITS;
const KIND_SHIFT: u5 = INDEX_BITS + GEN_BITS;
const RIGHTS_SHIFT: u5 = INDEX_BITS + GEN_BITS + KIND_BITS;

pub const Rights = struct {
    pub const send: u4 = 1 << 0;
    pub const receive: u4 = 1 << 1;
    pub const call: u4 = 1 << 2;
    pub const reply: u4 = 1 << 3;
};

const Kind = enum(u2) {
    endpoint = 1,
    caller = 2,
};

const HandleEntry = union(Kind) {
    endpoint: EndpointId,
    caller: *Task,
};

const Slot = struct {
    generation: u12 = 1,
    occupied: bool = false,
    kind: Kind = .endpoint,
    rights: u4 = 0,
    entry: HandleEntry = .{ .endpoint = 0 },
};

const ProcessHandles = struct {
    next_probe_index: usize = 0,
    slots: std.ArrayListUnmanaged(Slot) = .{},

    fn deinit(self: *ProcessHandles, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = .{};
    }

    fn allocSlotIndex(self: *ProcessHandles, allocator: std.mem.Allocator) !usize {
        const slot_count = self.slots.items.len;
        if (slot_count != 0) {
            var scanned: usize = 0;
            while (scanned < slot_count) : (scanned += 1) {
                const idx = (self.next_probe_index + scanned) % slot_count;
                if (!self.slots.items[idx].occupied) {
                    self.next_probe_index = (idx + 1) % slot_count;
                    return idx;
                }
            }
        }

        if (slot_count >= MAX_SLOTS) return error.OutOfHandles;

        try self.slots.append(allocator, .{});
        const idx = self.slots.items.len - 1;
        self.next_probe_index = if (self.slots.items.len == 0) 0 else (idx + 1) % self.slots.items.len;
        return idx;
    }

    fn encodeHandle(index: usize, generation: u12, kind: Kind, rights: u4) Handle {
        const idx = @as(u32, @intCast(index));
        return (idx & INDEX_MASK) |
            ((@as(u32, generation) & GEN_MASK) << GEN_SHIFT) |
            ((@as(u32, @intFromEnum(kind)) & KIND_MASK) << KIND_SHIFT) |
            ((@as(u32, rights) & RIGHTS_MASK) << RIGHTS_SHIFT);
    }

    fn decodeHandle(handle: Handle) ?struct {
        index: usize,
        generation: u12,
        kind: Kind,
        rights: u4,
    } {
        const raw_kind: u2 = @intCast((handle >> KIND_SHIFT) & KIND_MASK);
        const kind: Kind = switch (raw_kind) {
            @intFromEnum(Kind.endpoint) => .endpoint,
            @intFromEnum(Kind.caller) => .caller,
            else => return null,
        };

        return .{
            .index = @intCast(handle & INDEX_MASK),
            .generation = @intCast((handle >> GEN_SHIFT) & GEN_MASK),
            .kind = kind,
            .rights = @intCast((handle >> RIGHTS_SHIFT) & RIGHTS_MASK),
        };
    }

    fn install(self: *ProcessHandles, allocator: std.mem.Allocator, entry: HandleEntry, rights: u4) !Handle {
        const slot_index = try self.allocSlotIndex(allocator);

        var slot = &self.slots.items[slot_index];

        slot.occupied = true;
        slot.kind = std.meta.activeTag(entry);
        slot.rights = rights;
        slot.entry = entry;
        if (slot.generation == 0) slot.generation = 1;

        return encodeHandle(slot_index, slot.generation, slot.kind, slot.rights);
    }

    fn lookup(self: *ProcessHandles, handle: Handle, expected_kind: Kind, required_rights: u4) ?*Slot {
        const decoded = decodeHandle(handle) orelse return null;
        if (decoded.kind != expected_kind) return null;
        if (decoded.index >= self.slots.items.len) return null;

        const slot = &self.slots.items[decoded.index];
        if (!slot.occupied) return null;
        if (slot.generation != decoded.generation) return null;
        if (slot.kind != expected_kind) return null;
        if ((slot.rights & required_rights) != required_rights) return null;
        return slot;
    }

    fn freeSlot(_: *ProcessHandles, slot: *Slot) void {
        slot.occupied = false;
        slot.rights = 0;
        slot.entry = .{ .endpoint = 0 };

        var next_gen: u12 = slot.generation +% 1;
        if (next_gen == 0) next_gen = 1;
        slot.generation = next_gen;
    }
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
var by_pid: std.AutoHashMapUnmanaged(process.ProcessId, ProcessHandles) = .{};

pub fn init(allocator: std.mem.Allocator) void {
    lock.acquire();
    defer lock.release();

    if (global_allocator) |existing| {
        var it = by_pid.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(existing);
        }
        by_pid.deinit(existing);
    }

    by_pid = .{};
    global_allocator = allocator;
}

fn getOrCreate(pid: process.ProcessId) !*ProcessHandles {
    const allocator = global_allocator orelse return error.NotInitialized;
    const gop = try by_pid.getOrPut(allocator, pid);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

pub fn installEndpoint(pid: process.ProcessId, endpoint: EndpointId) !Handle {
    lock.acquire();
    defer lock.release();

    const owner = registry.ownerOf(endpoint) orelse return error.InvalidEndpoint;
    if (owner != pid) return error.PermissionDenied;

    var handles = try getOrCreate(pid);
    return handles.install(global_allocator.?, .{ .endpoint = endpoint }, Rights.send | Rights.receive | Rights.call);
}

pub fn resolveEndpoint(pid: process.ProcessId, handle: Handle, required_rights: u4) ?EndpointId {
    lock.acquire();
    defer lock.release();

    const handles = by_pid.getPtr(pid) orelse return null;
    const slot = handles.lookup(handle, .endpoint, required_rights) orelse return null;

    return switch (slot.entry) {
        .endpoint => |endpoint| endpoint,
        .caller => null,
    };
}

pub fn installCaller(pid: process.ProcessId, caller: *Task) !Handle {
    lock.acquire();
    defer lock.release();

    var handles = try getOrCreate(pid);
    return handles.install(global_allocator.?, .{ .caller = caller }, Rights.reply);
}

pub fn consumeCaller(pid: process.ProcessId, handle: Handle) ?*Task {
    lock.acquire();
    defer lock.release();

    const handles = by_pid.getPtr(pid) orelse return null;
    const slot = handles.lookup(handle, .caller, Rights.reply) orelse return null;

    const caller = switch (slot.entry) {
        .caller => |task| task,
        .endpoint => return null,
    };

    handles.freeSlot(slot);
    return caller;
}

pub fn revokeProcess(pid: process.ProcessId) void {
    lock.acquire();
    defer lock.release();

    const allocator = global_allocator orelse return;
    var removed = by_pid.fetchRemove(pid) orelse return;
    removed.value.deinit(allocator);
}
