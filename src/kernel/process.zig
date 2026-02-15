//! Process Management
//!
//! A Process owns an address space and groups one or more tasks.
//! For now, single-threaded: one process = one user task
//!
//! Lifecycle:
//!     create()        -> allocates Process + AddressSpace
//!     spawnTask()     -> creates a user-mode task inside this process
//!     exit()          -> marks process as exiting, task death handled by scheduler
//!
//! The process table is a simple fixed-size array indexed by PID.
//! PIDs are never reused (good enough until we hit 4 billion).

const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const mm = @import("mm");
const address_space = mm.address_space;
const vmm = mm.vmm;
const sched = @import("sched/core.zig");
const Task = @import("sched/task.zig");

pub const ProcessState = enum(u8) {
    /// Running normally
    alive,
    /// exit() called, task(s) being torn down
    exiting,
    /// Fully dead, resources reclaimable
    dead,
};

pub const Process = struct {
    pid: u32,
    addr_space: *address_space.AddressSpace,
    state: ProcessState = .alive,
    exit_code: i32 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    allocator: std.mem.Allocator,

    pub fn setName(self: *Process, src: []const u8) void {
        const len = @min(src.len, self.name.len - 1);
        @memcpy(self.name[0..len], src[0..len]);
        self.name[len] = 0;
    }

    pub fn nameSlice(self: *const Process) []const u8 {
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }
        return &self.name;
    }

    /// Called from the exit syscall path. Marks the process as exiting.
    /// The actual task death and scheduling is handled by the caller
    /// (sched.exit()).
    pub fn exit(self: *Process, code: i32) void {
        self.state = .exiting;
        self.exit_code = code;
        log.info("Process '{s}' (pid={}) exiting with code {}", .{
            self.nameSlice(), self.pid, code,
        });
    }

    /// Map anonymous pages into this process's address space.
    pub fn mapAnonymous(
        self: *Process,
        virt_start: u64,
        num_pages: usize,
        flags: vmm.MapFlags,
    ) !void {
        try self.addr_space.mapAnonymous(virt_start, num_pages, flags);
    }
};

// =============================================================================
// Process Table
// =============================================================================

const MAX_PROCESSES = 256;

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

var table: [MAX_PROCESSES]?*Process = [_]?*Process{null} ** MAX_PROCESSES;
var table_lock: SpinLock = .{};
var next_pid: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

fn allocPid() u32 {
    return next_pid.fetchAdd(1, .monotonic);
}

fn registerProcess(proc: *Process) void {
    table_lock.acquire();
    defer table_lock.release();

    // Simple modular index. Collisions overwrite
    const idx = proc.pid % MAX_PROCESSES;
    table[idx] = proc;
}

pub fn lookup(pid: u32) ?*Process {
    const idx = pid % MAX_PROCESSES;
    return table[idx];
}

// =============================================================================
// Creation
// =============================================================================

/// Create a new process with its own address space
pub fn create(
    allocator: std.mem.Allocator,
    name: []const u8,
) !*Process {
    const as = try address_space.AddressSpace.create(allocator);
    errdefer as.destroy(allocator);

    const proc = try allocator.create(Process);
    proc.* = .{
        .pid = allocPid(),
        .addr_space = as,
        .allocator = allocator,
    };
    proc.setName(name);

    registerProcess(proc);

    log.info("Process '{s}' created: pid={}", .{ proc.nameSlice(), proc.pid });
    return proc;
}

/// Spawn a user-mode task inside this process.
/// The task will enter user mode at `user_entry` with stack at `user_stack_top`
pub fn spawnTask(
    proc: *Process,
    user_entry: u64,
    user_stack_top: u64,
    prio: u5,
    name: []const u8,
) !*Task {
    const task = try sched.spawnUser(
        proc.addr_space,
        user_entry,
        user_stack_top,
        prio,
        name,
    );
    task.process = proc;
    return task;
}
