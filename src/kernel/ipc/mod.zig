//! IPC Subsystem - Public API
//!
//! ipc.init(allocator)             - initialize registry
//! ipc.createEndpoint()            - create a new endpoint, returns global endpoint ID
//! ipc.destroyEndpoint(id)         - destroy endpoint, wake all waiters
//! ipc.send(ep_id, &msg)           - blocking send
//! ipc.receive(ep_id)              - blocking receive -> {msg, caller}
//! ipc.call(ep_id, &msg, &reply)   - send + wait for reply
//! ipc.reply(caller, &msg)         - reply to a caller from call()
//! ipc.notify(ep_id)               - async notification (no payload)

const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const process = @import("../process/mod.zig");

pub const Message = @import("message.zig").Message;
pub const Endpoint = @import("endpoint.zig").Endpoint;
pub const WaitQueue = @import("endpoint.zig").WaitQueue;
pub const registry = @import("registry.zig");
pub const handles = @import("handles.zig");

pub const EndpointId = registry.EndpointId;
pub const EndpointToken = registry.EndpointToken;

const Task = @import("../sched/task.zig").Task;

pub fn init(allocator: std.mem.Allocator) void {
    registry.init(allocator);
    handles.init(allocator);
    log.info("IPC subsystem initialized", .{});
}

pub fn createEndpoint(owner_pid: process.ProcessId) !EndpointToken {
    return registry.create(owner_pid);
}

pub fn destroyEndpoint(tok: EndpointToken, caller_pid: process.ProcessId) !void {
    return registry.destroy(tok, caller_pid);
}

pub fn send(tok: EndpointToken, msg: *const Message) !void {
    const ep = registry.acquire(tok) orelse return error.InvalidEndpoint;
    defer registry.release(ep);
    return ep.send(msg);
}

pub fn receive(tok: EndpointToken) !Endpoint.ReceiveResult {
    const ep = registry.acquire(tok) orelse return error.InvalidEndpoint;
    defer registry.release(ep);
    return ep.receive();
}

pub fn call(tok: EndpointToken, msg: *const Message, reply_buf: *Message) !void {
    const ep = registry.acquire(tok) orelse return error.InvalidEndpoint;
    defer registry.release(ep);
    return ep.call(msg, reply_buf);
}

pub fn reply(caller: *Task, msg: *const Message) void {
    Endpoint.reply(caller, msg);
}

pub fn abortCaller(caller: *Task) void {
    Endpoint.abortCaller(caller);
}

pub fn notify(tok: EndpointToken) !void {
    const ep = registry.acquire(tok) orelse return error.InvalidEndpoint;
    defer registry.release(ep);
    return ep.notify();
}
