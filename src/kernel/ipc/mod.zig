//! IPC Subsystem - Public API
//!
//! ipc.init(allocator)             - initialize registry
//! ipc.createEndpoint()            - create a new endpoint, returns ID
//! ipc.destroyEndpoint(id)         - destroy endpoint, wake all waiters
//! ipc.send(ep_id, &msg)           - blocking send
//! ipc.receive(ep_id)              - blocking receive -> {msg, caller}
//! ipc.call(ep_id, &msg, &reply)   - send + wait for reply
//! ipc.reply(caller, &msg)         - reply to a caller from call()

const std = @import("std");
const shared = @import("shared");
const log = shared.log;

pub const Message = @import("message.zig").Message;
pub const Endpoint = @import("endpoint.zig").Endpoint;
pub const WaitQueue = @import("endpoint.zig").WaitQueue;
pub const registry = @import("registry.zig");
pub const EndpointId = registry.EndpointId;

const Task = @import("../sched/task.zig").Task;

pub fn init(allocator: std.mem.Allocator) void {
    registry.init(allocator);
    log.info("IPC subsystem initialized", .{});
}

pub fn createEndpoint() !EndpointId {
    return registry.create();
}

pub fn send(ep_id: EndpointId, msg: *const Message) !void {
    const ep = registry.lookup(ep_id) orelse return error.InvalidEndpoint;
    return ep.send(msg);
}

pub fn receive(ep_id: EndpointId) !Endpoint.ReceiveResult {
    const ep = registry.lookup(ep_id) orelse return error.InvalidEndpoint;
    return ep.receive();
}

pub fn call(ep_id: EndpointId, msg: *const Message, reply_buf: *Message) !void {
    const ep = registry.lookup(ep_id) orelse return error.InvalidEndpoint;
    return ep.call(msg, reply_buf);
}

pub fn reply(caller: *Task, msg: *const Message) void {
    Endpoint.reply(caller, msg);
}
