//! IPC Endpoint Registry
//!
//! Manages a table of endpoints indexed by integer handle (EndpointId).
//! Integer handles instead of raw pointers because:
//!     1. Safe across the syscall boundary (userspace can't forge pointers)
//!     2. Allows revocation and lifetime management
//!     3. Foundation for capability-based security later

const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const process = @import("../process/mod.zig");
const Endpoint = @import("endpoint.zig").Endpoint;

pub const EndpointId = u32;
pub const INVALID_EP: EndpointId = 0;

pub const EndpointToken = packed struct {
    id: EndpointId,
    gen: u32,
};

const MAX_ENDPOINTS = 4096;

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

const Slot = struct {
    ep: ?*Endpoint = null,
    owner: process.ProcessId = 0,
    gen: u32 = 1,
};

var lock: SpinLock = .{};
var slots: [MAX_ENDPOINTS]Slot = [_]Slot{.{}} ** MAX_ENDPOINTS;
var next_id: EndpointId = 1;
var allocator: ?std.mem.Allocator = null;

fn isValidId(id: EndpointId) bool {
    return id != INVALID_EP and id < MAX_ENDPOINTS;
}

fn slotMatchesToken(slot: *const Slot, tok: EndpointToken) bool {
    return slot.gen == tok.gen and slot.ep != null;
}

pub fn init(alloc: std.mem.Allocator) void {
    lock.acquire();
    defer lock.release();

    for (&slots) |*slot| {
        if (slot.ep) |ep| {
            ep.beginClose();
            ep.refPut();
        }
        slot.* = .{};
    }

    allocator = alloc;
    next_id = 1;

    log.info("IPC registry initialized: {} endpoint slots", .{MAX_ENDPOINTS});
}

/// Create a new endpoint and return a generation token.
/// Registry holds one ownership ref.
pub fn create(owner_pid: process.ProcessId) !EndpointToken {
    const alloc = allocator orelse return error.NotInitialized;

    lock.acquire();
    defer lock.release();

    const start = next_id;
    var id = start;

    while (true) {
        if (id == INVALID_EP) id = 1;
        if (id >= MAX_ENDPOINTS) id = 1;

        if (slots[id].ep == null) break;

        id += 1;
        if (id == start) return error.OutOfEndpoints;
    }

    const ep = alloc.create(Endpoint) catch return error.OutOfMemory;
    ep.* = Endpoint.init(id, alloc);

    const slot = &slots[id];
    slot.ep = ep;
    slot.owner = owner_pid;

    next_id = id + 1;

    const tok = EndpointToken{ .id = id, .gen = slot.gen };
    log.debug("IPC endpoint created: id={} gen={} owner_pid={}", .{ tok.id, tok.gen, owner_pid });
    return tok;
}

/// Acquire a ref to endpoint identified by token.
/// Returns null if token is invalid/stale/missing.
pub fn acquire(tok: EndpointToken) ?*Endpoint {
    if (!isValidId(tok.id)) return null;

    lock.acquire();
    defer lock.release();

    const slot = &slots[tok.id];
    if (!slotMatchesToken(slot, tok)) return null;

    const ep = slot.ep.?;
    if (!ep.refGet()) return null;

    return ep;
}

/// Release previously acquired endpoint ref.
pub fn release(ep: *Endpoint) void {
    ep.refPut();
}

/// Destroy endpoint token if caller owns it.
/// Safe against stale tokens and concurrent lookups.
/// Registry drops publication first, then closes endpoint outside registry lock.
pub fn destroy(tok: EndpointToken, caller_pid: process.ProcessId) error{ InvalidEndpoint, PermissionDenied, NotInitialized }!void {
    if (!isValidId(tok.id)) return error.InvalidEndpoint;
    _ = allocator orelse return error.NotInitialized;

    var ep_local: *Endpoint = undefined;

    lock.acquire();
    {
        const slot = &slots[tok.id];
        if (!slotMatchesToken(slot, tok)) {
            lock.release();
            return error.InvalidEndpoint;
        }
        if (slot.owner != caller_pid) {
            lock.release();
            return error.PermissionDenied;
        }

        ep_local = slot.ep.?;

        slot.ep = null;
        slot.owner = 0;

        var next_gen = slot.gen +% 1;
        if (next_gen == 0) next_gen = 1;
        slot.gen = next_gen;
    }
    lock.release();

    ep_local.beginClose();

    ep_local.refPut();

    log.debug("IPC endpoint destroyed: id={} gen={}", .{ tok.id, tok.gen });
}

/// Destroy every endpoint currently owned by `pid`.
/// Safe to call during process teardown; tolerates concurrent endpoint destroy.
pub fn destroyOwnedBy(pid: process.ProcessId) void {
    const alloc = allocator orelse return;
    var count: usize = 0;
    lock.acquire();
    for (1..MAX_ENDPOINTS) |i| {
        const slot = &slots[i];
        if (slot.ep != null and slot.owner == pid) count += 1;
    }
    lock.release();

    if (count == 0) return;

    var toks = std.ArrayListUnmanaged(EndpointToken){};
    defer toks.deinit(alloc);
    toks.ensureTotalCapacity(alloc, count) catch return;

    lock.acquire();
    for (1..MAX_ENDPOINTS) |i| {
        const id: EndpointId = @intCast(i);
        const slot = &slots[i];
        if (slot.ep == null) continue;
        if (slot.owner != pid) continue;
        toks.appendAssumeCapacity(.{
            .id = id,
            .gen = slot.gen,
        });
    }
    lock.release();

    for (toks.items) |tok| {
        destroy(tok, pid) catch |err| switch (err) {
            error.InvalidEndpoint => {},
            error.PermissionDenied => {},
            error.NotInitialized => return,
        };
    }

    log.debug("IPC registry: destroyed {} endpoint(s) for pid={}", .{
        toks.items.len, pid,
    });
}

/// Returns owner only when token exactly matches current live slot
pub fn ownerOf(tok: EndpointToken) ?process.ProcessId {
    if (!isValidId(tok.id)) return null;

    lock.acquire();
    defer lock.release();

    const slot = &slots[tok.id];
    if (!slotMatchesToken(slot, tok)) return null;
    if (slot.owner == 0) return null;
    return slot.owner;
}
