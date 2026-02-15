const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const MAX_CPUS = shared.types.MAX_CPUS;

const arch = @import("arch");
const sched_arch = arch.sched;

const mm = @import("mm");
const address_space = mm.address_space;

const task_mod = @import("task.zig");
const Task = task_mod.Task;
const TaskState = task_mod.TaskState;
const Priority = task_mod.Priority;

const queue_mod = @import("queue.zig");
const RunQueue = queue_mod.RunQueue;

const STEAL_BATCH_SIZE = 4;

pub const CpuSched = struct {
    queue: RunQueue = .{},
    current: ?*Task = null,
    idle_task: *Task = undefined,
    need_resched: bool = false,
    lock: SpinLock = .{},
    cpu_id: u32 = 0,
    tick_count: u64 = 0,
};

fn armCpuTimer(cs: *const CpuSched, task: *const Task) void {
    if (task == cs.idle_task and cs.queue.isEmpty()) {
        arch.timer.disarm();
        return;
    }

    var quantum_ms: u64 = task_mod.timeSliceForPriority(task.priority);
    if (quantum_ms == 0) quantum_ms = 1;
    arch.timer.armOneShotMs(quantum_ms);
}

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub inline fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub inline fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }

    pub inline fn tryAcquire(self: *SpinLock) bool {
        return self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) == null;
    }
};

var cpu_scheds: [MAX_CPUS]CpuSched = [_]CpuSched{.{}} ** MAX_CPUS;
var cpu_count: u32 = 0;
var alloc: std.mem.Allocator = undefined;
var initialized: bool = false;

pub fn init(allocator: std.mem.Allocator, num_cpus: u32) !void {
    alloc = allocator;
    cpu_count = num_cpus;

    for (0..num_cpus) |i| {
        cpu_scheds[i].cpu_id = @intCast(i);
        cpu_scheds[i].queue.cpu_id = @intCast(i);

        const idle = try createTask(idleEntry, 0, Priority.IDLE);
        idle.pinned = true;
        idle.cpu_id = @intCast(i);
        idle.setName("idle");
        idle.state = .ready;
        cpu_scheds[i].idle_task = idle;
    }

    initialized = true;
    log.info("Scheduler initialized: {} CPUs, 32 priority levels", .{num_cpus});
}

pub fn createTask(
    entry: sched_arch.TaskEntryFn,
    arg: usize,
    prio: u5,
) !*Task {
    const t = try alloc.create(Task);

    const stack = try alloc.alignedAlloc(u8, std.mem.Alignment.@"16", task_mod.KERNEL_STACK_SIZE);

    t.* = .{
        .tid = task_mod.allocTid(),
        .priority = prio,
        .base_priority = prio,
        .stack_base = @intFromPtr(stack.ptr),
        .stack_size = stack.len,
        .time_slice = task_mod.timeSliceForPriority(prio),
    };

    t.saved_sp = sched_arch.prepareContext(
        t.stack_base,
        t.stack_size,
        entry,
        arg,
    );

    return t;
}

/// Create a user mode task. The task starts in kernel mode running
/// `userTaskEntry`, which sets up the address space and drops to ring 3.
pub fn createUserTask(
    addr_space_ptr: *address_space.AddressSpace,
    user_entry: u64,
    user_stack_top: u64,
    prio: u5,
) !*Task {
    const t = try createTask(userTaskEntry, 0, prio);
    t.addr_space = addr_space_ptr;
    t.user_entry = user_entry;
    t.user_stack_top = user_stack_top;
    return t;
}

pub fn spawn(
    entry: sched_arch.TaskEntryFn,
    arg: usize,
    prio: u5,
    name: []const u8,
) !*Task {
    const t = try createTask(entry, arg, prio);
    t.setName(name);

    const target_cpu = leastLoadedCpu();
    t.cpu_id = target_cpu;
    enqueueOn(target_cpu, t);

    log.debug("Spawned task '{s}' tid={} prio={} -> CPU{}", .{
        t.nameSlice(),
        t.tid,
        prio,
        target_cpu,
    });

    return t;
}

/// Spawn a user-mode task
pub fn spawnUser(
    addr_space_ptr: *address_space.AddressSpace,
    user_entry: u64,
    user_stack_top: u64,
    prio: u5,
    name: []const u8,
) !*Task {
    const t = try createUserTask(addr_space_ptr, user_entry, user_stack_top, prio);
    t.setName(name);

    const target_cpu = leastLoadedCpu();
    t.cpu_id = target_cpu;
    enqueueOn(target_cpu, t);

    log.info("Spawned user task '{s}' tid={} prio={} -> CPU{} entry=0x{x} stack=0x{x}", .{
        t.nameSlice(),
        t.tid,
        prio,
        target_cpu,
        user_entry,
        user_stack_top,
    });

    return t;
}

/// Timer tick - called from arch interrupt handler
pub fn tick() void {
    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];
    cs.tick_count += 1;

    if (cs.current) |curr| {
        if (curr == cs.idle_task) {
            if (!cs.queue.isEmpty()) cs.need_resched = true;
            return;
        }

        curr.total_ticks += 1;
        curr.time_slice = 0;
        cs.need_resched = true;
    }
}

pub fn schedule() void {
    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];

    cs.lock.acquire();
    cs.need_resched = false;

    const old = cs.current orelse {
        const next = pickNext(cs);
        cs.current = next;
        next.state = .running;
        next.time_slice = task_mod.timeSliceForPriority(next.priority);
        prepareTaskSwitch(null, next);
        armCpuTimer(cs, next);
        cs.lock.release();
        sched_arch.loadContext(next.saved_sp);
        unreachable;
    };

    if (old.state == .running and old != cs.idle_task) {
        old.state = .ready;
        old.time_slice = task_mod.timeSliceForPriority(old.priority);
        cs.queue.enqueue(old);
    }

    const next = pickNext(cs);

    if (next == old) {
        old.state = .running;
        old.time_slice = task_mod.timeSliceForPriority(old.priority);
        armCpuTimer(cs, old);
        cs.lock.release();
        return;
    }

    cs.current = next;
    next.state = .running;
    next.time_slice = task_mod.timeSliceForPriority(next.priority);
    prepareTaskSwitch(old, next);
    armCpuTimer(cs, next);
    cs.lock.release();

    sched_arch.switchContext(&old.saved_sp, next.saved_sp);
}

/// Prepares the CPU for running `next` task.
/// Handles:
///     - Saving arch-specific state for the outgoing user task
///     - Address space activation
///     - Restoring arch-specific state for the incoming user task
fn prepareTaskSwitch(old: ?*Task, next: *Task) void {
    // Save arch-specific state for outgoing user task
    if (old) |o| {
        if (o.isUserTask()) {
            sched_arch.saveUserState(&o.arch_state);
        }
    }

    // Activate the next task's address space
    if (next.addr_space) |as| {
        as.activate();
    } else {
        if (old) |o| {
            if (o.isUserTask()) {
                address_space.activateKernel();
            }
        }
    }

    // Restore arch-specific state for incoming user task
    if (next.isUserTask()) {
        sched_arch.loadUserState(&next.arch_state, next.kernelStackTop());
    }
}

fn pickNext(cs: *CpuSched) *Task {
    if (cs.queue.dequeue()) |t| return t;
    if (trySteal(cs)) |t| return t;
    return cs.idle_task;
}

fn trySteal(cs: *CpuSched) ?*Task {
    if (cpu_count <= 1) return null;

    var busiest_id: u32 = 0;
    var busiest_load: u32 = 0;

    for (0..cpu_count) |i| {
        const id: u32 = @intCast(i);
        if (id == cs.cpu_id) continue;
        const load = cpu_scheds[id].queue.total;
        if (load > busiest_load) {
            busiest_load = load;
            busiest_id = id;
        }
    }

    if (busiest_load < 2) return null;

    const victim = &cpu_scheds[busiest_id];

    if (!victim.lock.tryAcquire()) return null;
    defer victim.lock.release();

    var stolen_buf: [STEAL_BATCH_SIZE]*Task = undefined;
    const n = victim.queue.stealBatch(&stolen_buf, STEAL_BATCH_SIZE);
    if (n == 0) return null;

    const first_task = stolen_buf[0];
    first_task.cpu_id = cs.cpu_id;

    for (1..n) |j| {
        stolen_buf[j].cpu_id = cs.cpu_id;
        cs.queue.enqueue(stolen_buf[j]);
    }

    return first_task;
}

pub fn yield() void {
    const flags = sched_arch.disableIrq();
    defer sched_arch.restoreIrq(flags);

    schedule();
}

pub fn block(wait_channel: ?*anyopaque) void {
    const flags = sched_arch.disableIrq();

    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];

    if (cs.current) |curr| {
        curr.state = .blocked;
        curr.wait_channel = wait_channel;
    }

    schedule();
    sched_arch.restoreIrq(flags);
}

pub fn wake(t: *Task) void {
    const flags = sched_arch.disableIrq();
    defer sched_arch.restoreIrq(flags);

    if (t.state != .blocked) return;

    t.state = .ready;
    t.wait_channel = null;
    t.time_slice = task_mod.timeSliceForPriority(t.priority);
    enqueueOn(t.cpu_id, t);
}

pub fn exit() noreturn {
    _ = sched_arch.disableIrq();

    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];

    if (cs.current) |curr| {
        curr.state = .dead;
        log.debug("Task '{s}' (tid={}) exited", .{
            curr.nameSlice(),
            curr.tid,
        });
    }

    schedule();
    unreachable;
}

fn enqueueOn(cpu_id: u32, t: *Task) void {
    const cs = &cpu_scheds[cpu_id];
    const local_cpu = sched_arch.getCpuId();

    cs.lock.acquire();
    cs.queue.enqueue(t);

    if (cpu_id == local_cpu) {
        if (cs.current) |curr| {
            if (t.priority < curr.priority) cs.need_resched = true;
        } else {
            cs.need_resched = true;
        }
    }

    cs.lock.release();

    if (cpu_id != local_cpu) {
        arch.smp.requestResched(cpu_id);
    }
}

fn leastLoadedCpu() u32 {
    var best_id: u32 = 0;
    var best_load: u32 = std.math.maxInt(u32);

    for (0..cpu_count) |i| {
        const load = cpu_scheds[@intCast(i)].queue.total;
        if (load < best_load) {
            best_load = load;
            best_id = @intCast(i);
        }
    }

    return best_id;
}

pub fn getCpuSched(cpu_id: u32) *CpuSched {
    return &cpu_scheds[cpu_id];
}

pub fn currentTask() ?*Task {
    const cpu_id = sched_arch.getCpuId();
    return cpu_scheds[cpu_id].current;
}

pub fn needsResched() bool {
    const cpu_id = sched_arch.getCpuId();
    return cpu_scheds[cpu_id].need_resched;
}

pub fn requestResched() void {
    const cpu_id = sched_arch.getCpuId();
    cpu_scheds[cpu_id].need_resched = true;
}

fn idleEntry(_: usize) callconv(.c) noreturn {
    while (true) {
        sched_arch.haltUntilInterrupt();
    }
}

/// Kernel entry point for user-mode tasks.
/// The scheduler runs this as a normal kernel task. It activates the
/// address space, then delegates to the arch layer to configure CPU and
/// drop to user mode.
fn userTaskEntry(_: usize) callconv(.c) noreturn {
    const task = currentTask() orelse @panic("userTaskEntry: no current task");

    const as = task.addr_space orelse @panic("userTaskEntry: task has no address space");

    log.info("User task '{s}' (tid={}) entering user mode: entry=0x{x} stack=0x{x}", .{
        task.nameSlice(),
        task.tid,
        task.user_entry,
        task.user_stack_top,
    });

    // Activate user address space
    as.activate();

    // Arch layer handles CPU config and mode transition
    // Never returns
    sched_arch.enterInitialUserMode(task.kernelStackTop(), task.user_entry, task.user_stack_top);
}

extern const __boot_stack_bottom: u8;
extern const __boot_stack_top: u8;

pub fn startOnBsp() !void {
    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];

    const boot_task = try alloc.create(Task);
    boot_task.* = .{
        .tid = 0,
        .state = .running,
        .priority = Priority.NORMAL_DEFAULT,
        .cpu_id = cpu_id,
        .time_slice = task_mod.timeSliceForPriority(Priority.NORMAL_DEFAULT),
        .stack_base = @intFromPtr(&__boot_stack_bottom),
        .stack_size = @intFromPtr(&__boot_stack_top) - @intFromPtr(&__boot_stack_bottom),
    };

    boot_task.setName("boot");
    cs.current = boot_task;
    armCpuTimer(cs, boot_task);

    log.info("Scheduler started on BSP (CPU{})", .{cpu_id});
}

pub fn startOnAp() void {
    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];

    cs.current = cs.idle_task;
    cs.idle_task.state = .running;
    armCpuTimer(cs, cs.idle_task);

    log.debug("Scheduler started on AP (CPU{})", .{cpu_id});
}

pub fn onUserException(vec: u8, err: u64, rip: u64, cr2: u64) void {
    const cpu_id = sched_arch.getCpuId();
    const cs = &cpu_scheds[cpu_id];
    const curr = cs.current orelse @panic("user exception: no current task");

    if (!curr.isUserTask()) @panic("user exception on non-user task");

    log.warn("Killing user task '{s}' tid={} vec={} err=0x{x} rip=0x{x} cr2=0x{x}", .{
        curr.nameSlice(), curr.tid, vec, err, rip, cr2,
    });

    curr.state = .dead;
    cs.need_resched = true;
}
