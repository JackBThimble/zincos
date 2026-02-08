const std = @import("std");
const shared = @import("shared");
const arch = @import("arch");
const percpu = arch.percpu;

pub const TaskState = enum(u8) {
    /// In a run queue, eligible for scheduling
    ready,
    /// Currently executing on a CPU
    running,
    /// Waiting on some event (I/O, IPC, lock, timer...)
    blocked,
    /// Finished execution; resources can be reclaimed
    dead,
};

/// Priority bands. Lower number = higher priority.
/// Within each band, tasks are scheduled round-robin.
pub const Priority = enum(u5) {
    // --- Real-time band (0-7) ---
    pub const RT_MIN: u5 = 0;
    pub const RT_MAX: u5 = 7;

    // --- System / kernel threads (8-15) ---
    pub const SYS_MIN: u5 = 8;
    pub const SYS_MAX: u5 = 15;

    // --- Normal interactive (16-23) ---
    pub const NORMAL_MIN: u5 = 16;
    pub const NORMAL_MAX: u5 = 23;
    pub const NORMAL_DEFAULT: u5 = 20;

    // --- Background / batch (24-27) ---
    pub const BATCH_MIN: u5 = 24;
    pub const BATCH_MAX: u5 = 27;

    // --- Idle (28-31) - one per CPU, always runnable ---
    pub const IDLE_MIN: u5 = 28;
    pub const IDLE: u5 = 31;

    _,

    pub fn val(self: Priority) u5 {
        return @intFromEnum(self);
    }

    pub fn from(v: u5) Priority {
        return @enumFromInt(v);
    }
};

/// Time slice in scheduler ticks for a given priority.
/// Higher-priority tasks get shorter, more responsive slices.
/// Lower-priority tasks get longer slices for throughput.
pub fn timeSliceForPriority(prio: u5) u32 {
    return switch (prio) {
        0...7 => 1, // RT: preempt ASAP
        8...15 => 2, // System
        16...23 => 4, // Normal
        24...27 => 8, // Batch
        28...31 => 1, // Idle: yield immediately when real work shows up
    };
}

pub const KERNEL_STACK_SIZE: usize = 32 * 1024; // 32 KiB per task

pub const Task = struct {
    // --- Identity ---
    tid: u32,
    name: [32]u8 = [_]u8{0} ** 32,

    // --- Scheduling state ---
    state: TaskState = .ready,
    priority: u5 = Priority.NORMAL_DEFAULT,
    base_priority: u5 = Priority.NORMAL_DEFAULT,
    time_slice: u32 = 0, // ticks remaining in current quantum
    total_ticks: u64 = 0, // lifetime tick count

    // --- CPU affinity ---
    cpu_id: u32 = 0, // CPU this task is assigned to (for per-CPU queues)
    pinned: bool = false, // if true, never migrate

    /// Arch-opaque saved stack pointer.
    saved_sp: u64 = 0,

    // --- Kernel stack ---
    stack_base: u64 = 0, // bottom of allocated stack
    stack_size: usize = KERNEL_STACK_SIZE,

    // --- Intrusive linked list for run queues ---
    next: ?*Task = null,
    prev: ?*Task = null,

    // --- Blocking ---
    /// Opaque pointer to whatever this task is blocked on
    wait_channel: ?*anyopaque = null,

    pub fn setName(self: *Task, src: []const u8) void {
        const len = @min(src.len, self.name.len - 1);
        @memcpy(self.name[0..len], src[0..len]);
        self.name[len] = 0;
    }

    pub fn nameSlice(self: *const Task) []const u8 {
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }
        return &self.name;
    }
};

var next_tid: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

pub fn allocTid() u32 {
    return next_tid.fetchAdd(1, .monotonic);
}
