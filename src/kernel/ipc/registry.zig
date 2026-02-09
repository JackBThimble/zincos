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

const Endpoint = @import("endpoint.zig").Endpoint;

pub const EndpointId = u32;
pub const INVALID_EP: EndpointId = 0;

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

var lock: SpinLock = .{};
var table: [MAX_ENDPOINTS]?*Endpoint = [_]?*Endpoint{null} ** MAX_ENDPOINTS;
var next_id: EndpointId = 1;
var allocator: ?std.mem.Allocator = null;

pub fn init(alloc: std.mem.Allocator) void {
    allocator = alloc;
    log.info("IPC registry initialized: {} endpoint slots", .{MAX_ENDPOINTS});
}

// =============================================================================
// Create / Destroy / Lookup
// =============================================================================

pub fn create() !EndpointId {
    const alloc = allocator orelse return error.NotInitialized;

    lock.acquire();
    defer lock.release();

    const start = next_id;
    var id = start;

    while (true) {
        if (id == 0) id = 1;
        if (id >= MAX_ENDPOINTS) id = 1;

        if (table[id] == null) break;

        id += 1;
        if (id == start) return error.OutOfEndpoints;
    }

    const ep = alloc.create(Endpoint) catch return error.OutOfMemory;
    ep.* = Endpoint.init(id);
    table[id] = ep;

    next_id = id + 1;

    log.debug("IPC endpoint created: id={}", .{id});
    return id;
}

pub fn destroy(id: EndpointId) void {
    const alloc = allocator orelse return;

    lock.acquire();
    const ep = table[id] orelse {
        lock.release();
        return;
    };

    table[id] = null;
    lock.release();

    // Destroy wakes all waiters - must be done outside registry lock
    // to avoid lock inversion (endpoint lock -> scheduler lock)
    ep.destroy();
    alloc.destroy(ep);

    log.debug("IPC endpoint destroyed: id={}", .{id});
}

pub fn lookup(id: EndpointId) ?*Endpoint {
    if (id == INVALID_EP or id >= MAX_ENDPOINTS) return null;

    // No lock needed for read - pointer is stable once set.
    // Caller must handle the endpoint being destroyed between
    // lookup and use (the endpoint's own lock handles that).
    return table[id];
}
