//! IPC Endpoint
//!
//! Synchronous rendezvous-based IPC endpoint.
//!
//! Design:
//!     - Senders and receivers block until a partner arrives.
//!     - When both are present, the message is copied directly between
//!       task IPC buffers (no intermediate kernel buffer)
//!     - call/reply pattern: caller sends + blocks for reply. Server
//!       receives the message with a caller handle, processes it, then
//!       replies directly to the caller.
//!
//! Lock ordering:
//!     1. IRQs disabled
//!     2. Endpoint lock
//!     3. CPU scheduler lock (inside sched.wake -> enqueueOn)
//!
//! Note:
//! - Never hold the scheduler lock while acquiring an enpoint lock.

const std = @import("std");
const shared = @import("shared");
const log = shared.log;

const arch = @import("arch");
const sched_arch = arch.sched;

const sched = @import("../sched/core.zig");
const Task = @import("../sched/task.zig").Task;
const Message = @import("message.zig").Message;

// =============================================================================
// Wait Queue (intrusive, FIFO, uses task next/prev)
// =============================================================================
//
// Safe to reuse task.next/prev because a blocked task is never in a runqueue

pub const WaitQueue = struct {
    head: ?*Task = null,
    tail: ?*Task = null,
    count: u32 = 0,

    pub fn enqueue(self: *WaitQueue, t: *Task) void {
        t.next = null;
        t.prev = self.tail;
        if (self.tail) |tail| tail.next = t else self.head = t;
        self.tail = t;
        self.count += 1;
    }

    pub fn dequeue(self: *WaitQueue) ?*Task {
        const t = self.head orelse return null;
        self.head = t.next;
        if (t.next) |next| next.prev = null else self.tail = null;
        t.next = null;
        t.prev = null;
        self.count -= 1;
        return t;
    }

    pub fn remove(self: *WaitQueue, t: *Task) void {
        if (t.prev) |prev| prev.next = t.next else self.head = t.next;
        if (t.next) |next| next.prev = t.prev else self.tail = t.prev;
        t.next = null;
        t.prev = null;
        self.count -= 1;
    }

    pub fn isEmpty(self: *const WaitQueue) bool {
        return self.count == 0;
    }
};

// =============================================================================
// SpinLock
// =============================================================================

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

// =============================================================================
// Endpoint
// =============================================================================

pub const Endpoint = struct {
    id: u32,
    lock: SpinLock = .{},
    send_queue: WaitQueue = .{},
    recv_queue: WaitQueue = .{},
    pending_notifications: u64 = 0,
    alive: bool = true,

    pub fn init(id: u32) Endpoint {
        return .{ .id = id };
    }

    // =========================================================================
    // send - blocking send, returns when message is delivered
    // =========================================================================
    pub fn send(self: *Endpoint, msg: *const Message) error{EndpointClosed}!void {
        const task = sched.currentTask() orelse unreachable;
        const flags = sched_arch.disableIrq();

        self.lock.acquire();

        if (!self.alive) {
            self.lock.release();
            sched_arch.restoreIrq(flags);
            return error.EndpointClosed;
        }

        // Hot path: receiver already waiting
        if (self.recv_queue.dequeue()) |receiver| {
            // Direct transfer: sender's msg -> receiver's IPC buffer
            receiver.ipc.msg = msg.*;
            receiver.ipc.caller = task;

            self.lock.release();
            sched_arch.restoreIrq(flags);

            sched.wake(receiver);
            return;
        }

        // slow path: no receiver, block until one arrives
        task.ipc.msg = msg.*;
        task.ipc.waiting_for_reply = false;
        task.state = .blocked;

        self.send_queue.enqueue(task);
        self.lock.release();

        // Schedule away. We return here when a receiver wakes us.
        sched.schedule();
        sched_arch.restoreIrq(flags);
    }

    pub fn notify(self: *Endpoint) error{EndpointClosed}!void {
        const flags = sched_arch.disableIrq();
        self.lock.acquire();

        if (!self.alive) {
            self.lock.release();
            sched_arch.restoreIrq(flags);
            return error.EndpointClosed;
        }

        self.pending_notifications +%= 1;

        if (self.recv_queue.dequeue()) |receiver| {
            var notify_msg = Message.init(0xffff_fffe, 1);
            notify_msg.data[0] = self.pending_notifications;
            receiver.ipc.msg = notify_msg;
            receiver.ipc.caller = null;
            self.pending_notifications -= 1;

            self.lock.release();
            sched_arch.restoreIrq(flags);
            sched.wake(receiver);
            return;
        }

        self.lock.release();
        sched_arch.restoreIrq(flags);
    }

    // =========================================================================
    // receive - blocking receive, returns message + caller handle
    // =========================================================================
    pub const ReceiveResult = struct {
        msg: Message,
        caller: ?*Task, // non-null if sender used call() and expects a reply
    };

    pub fn receive(self: *Endpoint) error{EndpointClosed}!ReceiveResult {
        const task = sched.currentTask() orelse unreachable;
        const flags = sched_arch.disableIrq();

        self.lock.acquire();

        if (!self.alive) {
            self.lock.release();
            sched_arch.restoreIrq(flags);
            return error.EndpointClosed;
        }

        if (self.pending_notifications != 0) {
            self.pending_notifications -= 1;
            self.lock.release();
            sched_arch.restoreIrq(flags);

            return ReceiveResult{
                .msg = Message{
                    .tag = @as(u64, 0xffff_fffe) | (@as(u64, 1) << 32),
                    .data = .{ 1, 0, 0, 0, 0, 0 },
                },
                .caller = null,
            };
        }

        // Hot path: sender already waiting
        if (self.send_queue.dequeue()) |sender| {
            const result = ReceiveResult{
                .msg = sender.ipc.msg,
                .caller = if (sender.ipc.waiting_for_reply) sender else null,
            };

            self.lock.release();
            sched_arch.restoreIrq(flags);

            // If sender did send() (not call), wake it now
            if (!sender.ipc.waiting_for_reply) {
                sched.wake(sender);
            }

            // If sender did call(), it stays blocked until reply()
            return result;
        }

        // Slow path: no sender, block until one arrives
        task.state = .blocked;

        self.recv_queue.enqueue(task);
        self.lock.release();

        // Schedule away. We return here when a sender wakes us.
        sched.schedule();
        sched_arch.restoreIrq(flags);

        return ReceiveResult{
            .msg = task.ipc.msg,
            .caller = task.ipc.caller,
        };
    }

    // =========================================================================
    // call - send + block for reply (most common IPC pattern)
    // =========================================================================
    pub fn call(self: *Endpoint, msg: *const Message, msg_reply: *Message) error{EndpointClosed}!void {
        const task = sched.currentTask() orelse unreachable;
        const flags = sched_arch.disableIrq();
        _ = msg_reply;

        self.lock.acquire();

        if (!self.alive) {
            self.lock.release();
            sched_arch.restoreIrq(flags);
            return error.EndpointClosed;
        }

        // Set up the call state BEFORE anything else
        task.ipc.msg = msg.*;
        task.ipc.reply_buf = null;
        task.ipc.waiting_for_reply = true;

        // Hot path: receiver already waiting
        if (self.recv_queue.dequeue()) |receiver| {
            receiver.ipc.msg = msg.*;
            receiver.ipc.caller = task;

            // caller stays blocked (waiting_for_reply = true)
            task.state = .blocked;

            self.lock.release();

            // wake receiver, schedule away from caller
            sched.wake(receiver);
            sched.schedule();
            sched_arch.restoreIrq(flags);

            // we get here when reply() wakes us.
            // reply data was written directly to our reply buffer.
            return;
        }

        // Slow path: no receiver, block on send queue
        task.state = .blocked;

        self.send_queue.enqueue(task);
        self.lock.release();

        sched.schedule();
        sched_arch.restoreIrq(flags);

        // reply() already wrote to our reply buffer
    }

    // =========================================================================
    // reply - non-blocking, sends reply to a caller from call()
    // =========================================================================
    pub fn reply(caller: *Task, msg: *const Message) void {
        caller.ipc.msg = msg.*;

        caller.ipc.waiting_for_reply = false;
        caller.ipc.reply_buf = null;

        sched.wake(caller);
    }

    // =========================================================================
    // Teardown - wake all waiters with error
    // =========================================================================
    pub fn destroy(self: *Endpoint) void {
        const flags = sched_arch.disableIrq();
        self.lock.acquire();

        self.alive = false;

        while (self.send_queue.dequeue()) |task| {
            task.ipc.waiting_for_reply = false;
            sched.wake(task);
        }

        while (self.recv_queue.dequeue()) |task| {
            sched.wake(task);
        }

        self.lock.release();
        sched_arch.restoreIrq(flags);
    }
};
