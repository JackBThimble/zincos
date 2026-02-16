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
const sched = @import("../sched/mod.zig").core;
const Task = @import("../sched/task.zig").Task;
const elf_loader = @import("../elf/loader.zig");

pub const ProcessId = u32;
pub const UserStartArgs = sched.UserStartArgs;

pub const ProcessState = enum(u8) {
    starting,
    running,
    exiting,
    dead,
};

pub const Process = struct {
    pid: ProcessId,
    name: [32]u8 = [_]u8{0} ** 32,
    state: ProcessState = .starting,
    addr_space: *mm.address_space.AddressSpace,
    main_task: *Task,

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
};

const USER_STACK_PAGES: usize = 8;
const USER_STACK_TOP: u64 = 0x0000_0080_7000_0000;

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

var registry_allocator: ?std.mem.Allocator = null;
var registry_lock: SpinLock = .{};
var process_table: std.ArrayListUnmanaged(*Process) = .{};
var next_pid: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

pub fn init(allocator: std.mem.Allocator) void {
    registry_lock.acquire();
    defer registry_lock.release();

    registry_allocator = allocator;
    process_table.clearRetainingCapacity();

    log.info("Process manager initialized", .{});
}

fn allocPid() ProcessId {
    return next_pid.fetchAdd(1, .monotonic);
}

fn registerProcess(p: *Process) !void {
    const allocator = registry_allocator orelse return error.NotInitialized;

    registry_lock.acquire();
    defer registry_lock.release();

    try process_table.append(allocator, p);
}

pub fn createFromElf(
    allocator: std.mem.Allocator,
    name: []const u8,
    elf_image: []const u8,
    priority: u5,
) !*Process {
    return createFromElfWithArgs(allocator, name, elf_image, priority, .{});
}

pub fn createFromElfWithArgs(
    allocator: std.mem.Allocator,
    name: []const u8,
    elf_image: []const u8,
    priority: u5,
    start_args: UserStartArgs,
) !*Process {
    const as = try mm.address_space.AddressSpace.create(allocator);
    errdefer as.destroy(allocator);

    const loaded = try elf_loader.loadIntoAddressSpace(as, elf_image);

    const stack_base = USER_STACK_TOP - USER_STACK_PAGES * mm.PAGE_SIZE;
    try as.mapAnonymous(stack_base, USER_STACK_PAGES, mm.vmm.MapFlags.user_stack);

    const task = try sched.spawnUser(as, loaded.entry, USER_STACK_TOP, priority, name, start_args);

    const proc = try allocator.create(Process);
    proc.* = .{
        .pid = allocPid(),
        .state = .running,
        .addr_space = as,
        .main_task = task,
    };
    proc.setName(name);

    task.pid = proc.pid;

    try registerProcess(proc);

    log.info("Spawned process pid={} name='{s}' tid={} entry=0x{x}", .{
        proc.pid,
        proc.nameSlice(),
        task.tid,
        loaded.entry,
    });

    return proc;
}

pub fn lookup(pid: ProcessId) ?*Process {
    registry_lock.acquire();
    defer registry_lock.release();
    for (process_table.items) |p| {
        if (p.pid == pid) return p;
    }
    return null;
}

pub fn currentPid() ProcessId {
    const current = sched.currentTask() orelse return 0;
    return current.pid;
}
