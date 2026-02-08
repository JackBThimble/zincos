//! RunQueue - per-cpu priority based run queue
//!
//! 32 priority levels backed by doubly-linked FIFOs.
//! A 32-bit bitmap tracks which levels have runnable tasks
//! Highest priority lookup: O(1) via @ctz on bitmap.

const std = @import("std");
const task_mod = @import("task.zig");
const Task = task_mod.Task;
const Priority = task_mod.Priority;

pub const PRIORITY_LEVELS = 32;

const List = struct {
    head: ?*Task = null,
    tail: ?*Task = null,
    count: u32 = 0,
};

pub const RunQueue = struct {
    lists: [PRIORITY_LEVELS]List = [_]List{.{}} ** PRIORITY_LEVELS,
    bitmap: u32 = 0,
    total: u32 = 0,
    cpu_id: u32 = 0,

    pub fn enqueue(self: *RunQueue, t: *Task) void {
        std.debug.assert(t.state == .ready);

        const prio: usize = t.priority;
        const list = &self.lists[prio];

        t.next = null;
        t.prev = list.tail;

        if (list.tail) |tail| {
            tail.next = t;
        } else {
            list.head = t;
        }
        list.tail = t;
        list.count += 1;

        self.bitmap |= @as(u32, 1) << @intCast(prio);
        self.total += 1;
    }

    pub fn remove(self: *RunQueue, t: *Task) void {
        const prio: usize = t.priority;
        const list = &self.lists[prio];

        if (t.prev) |prev| prev.next = t.next else list.head = t.next;
        if (t.next) |next| next.prev = t.prev else list.tail = t.prev;

        t.prev = null;
        t.next = null;
        list.count -= 1;

        if (list.count == 0) {
            self.bitmap &= ~(@as(u32, 1) << @intCast(prio));
        }

        std.debug.assert(self.total > 0);
        self.total -= 1;
    }

    pub fn dequeue(self: *RunQueue) ?*Task {
        if (self.bitmap == 0) return null;

        const prio: usize = @ctz(self.bitmap);
        const list = &self.lists[prio];

        const t = list.head orelse unreachable;
        list.head = t.next;
        if (t.next) |next| {
            next.prev = null;
        } else {
            list.tail = null;
        }
        t.prev = null;
        t.next = null;
        list.count -= 1;

        if (list.count == 0) {
            self.bitmap &= ~(@as(u32, 1) << @intCast(prio));
        }
        self.total -= 1;
        return t;
    }

    pub fn peek(self: *const RunQueue) ?*const Task {
        if (self.bitmap == 0) return null;
        const prio: usize = @ctz(self.bitmap);
        return self.lists[prio].head;
    }

    pub fn hasHigherPriority(self: *const RunQueue, prio: u5) bool {
        const mask = (@as(u32, 1) << prio) - 1;
        return (self.bitmap & mask) != 0;
    }

    pub fn stealBatch(self: *RunQueue, out: []*Task, max: usize) usize {
        if (self.bitmap == 0 or max == 0) return 0;

        var stolen: usize = 0;
        var prio_i: i32 = 31;

        while (prio_i >= 0 and stolen < max) : (prio_i -= 1) {
            const prio: usize = @intCast(prio_i);
            if (prio >= Priority.IDLE_MIN) continue;

            const list = &self.lists[prio];
            while (list.tail != null and stolen < max) {
                const t = list.tail.?;
                if (t.pinned) break;

                if (t.prev) |prev| {
                    prev.next = null;
                    list.tail = prev;
                } else {
                    list.head = null;
                    list.tail = null;
                }
                t.prev = null;
                t.next = null;
                list.count -= 1;

                if (list.count == 0) {
                    self.bitmap &= ~(@as(u32, 1) << @intCast(prio));
                }
                self.total -= 1;

                out[stolen] = t;
                stolen += 1;
            }
        }
        return stolen;
    }

    pub fn isEmpty(self: *const RunQueue) bool {
        return self.bitmap == 0;
    }
};
