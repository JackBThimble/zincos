const std = @import("std");
const types = @import("types.zig");

// ----------------------
// Enums
// ----------------------
pub const Color = enum {
    red,
    green,
    yellow,
    cyan,
    reset,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
            .reset => "\x1b[0m",
        };
    }
};

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn color(self: Level) Color {
        return switch (self) {
            .err => .red,
            .warn => .yellow,
            .info => .green,
            .debug => .cyan,
        };
    }

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .err => "ERR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DBG",
        };
    }
};

// =====================================
// Comptime log level filter
// Change this to .info or .warn later
// =====================================
pub const LOG_LEVEL: Level = .debug;

// ====================================
// Function pointer types
// ====================================
pub const WriteFn = *const fn (bytes: []const u8) void;
pub const CpuIdFn = *const fn () usize;
pub const TscFn = *const fn () u64;

// ===================================
// Backends (injected by kernel)
// ===================================
var write_fn: ?WriteFn = null;
var emergency_write_fn: ?WriteFn = null;
var cpu_id_fn: ?CpuIdFn = null;
var tsc_fn: ?TscFn = null;

const MAX_CPUS = types.MAX_CPUS;
// const LOG_LOCK_SPIN_LIMIT: usize = 1_000_000;
var cpu_log_depth: [MAX_CPUS]std.atomic.Value(u32) = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** MAX_CPUS;

// ==================================
// Spinlock (SMP-safe)
// ==================================
var lock: SpinLock = .{};

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Acquire the lock, disabling interrupts to prevent preemption.
    /// Returns saved RFLAGS so release() can restore interrupt state.
    pub fn acquire(self: *SpinLock) u64 {
        // Save current flags and disable interrupts before spinning
        const flags = readFlags();
        asm volatile ("cli" ::: .{ .memory = true });

        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
        return flags;
    }

    /// Release the lock and restore the saved interrupt state.
    pub fn release(self: *SpinLock, flags: u64) void {
        self.locked.store(false, .release);
        // Restore IF only if it was originally set
        if (flags & 0x200 != 0) {
            asm volatile ("sti" ::: .{ .memory = true });
        }
    }

    inline fn readFlags() u64 {
        return asm volatile ("pushfq; pop %[flags]"
            : [flags] "=r" (-> u64),
        );
    }
};

// =====================================
// Public setup API
// =====================================
pub fn setWriter(w: WriteFn) void {
    if (emergency_write_fn == null) emergency_write_fn = w;
    write_fn = w;
}

pub fn setEmergencyWriter(w: WriteFn) void {
    emergency_write_fn = w;
}

pub fn setCpuId(f: CpuIdFn) void {
    cpu_id_fn = f;
}

pub fn setTscFn(f: TscFn) void {
    tsc_fn = f;
}

fn currentCpuSlot() usize {
    const cpu_id = if (cpu_id_fn) |f| f() else 0;
    return if (cpu_id < MAX_CPUS) cpu_id else 0;
}

fn enterLog(cpu_slot: usize) bool {
    const prev = cpu_log_depth[cpu_slot].fetchAdd(1, .acquire);
    return prev == 0;
}

fn leaveLog(cpu_slot: usize) void {
    _ = cpu_log_depth[cpu_slot].fetchSub(1, .release);
}

fn emergencyWrite(bytes: []const u8) void {
    if (emergency_write_fn) |w| {
        w(bytes);
        return;
    }
    if (write_fn) |w| w(bytes);
}

// =====================================
// Core logger
// =====================================

fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    // Filter log levels
    if (@intFromEnum(level) > @intFromEnum(LOG_LEVEL)) return;
    // Is backend set??
    const primary = write_fn orelse return;

    var buf: [1024]u8 = undefined;

    const cpu_id: usize = if (cpu_id_fn) |f| f() else 0;
    const tsc: u64 = if (tsc_fn) |f| f() else 0;

    // Format string:
    // [    TSC][CPUx][LEVEL] message
    const full_fmt =
        "{s}[{d:>12}][CPU{d}][{s}] - " ++ fmt ++ "{s}\n";

    const all_args = .{ level.color().code(), tsc, cpu_id, level.name() } ++ args ++ .{Color.reset.code()};
    const out_str = std.fmt.bufPrint(&buf, full_fmt, all_args) catch return;

    const cpu_slot = currentCpuSlot();
    const first_entry = enterLog(cpu_slot);
    defer leaveLog(cpu_slot);

    if (!first_entry) {
        // Avoid re-entrant recursive logging corruption
        return;
    }

    primary(out_str);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn raw(bytes: []const u8) void {
    const primary = write_fn orelse {
        emergencyWrite(bytes);
        return;
    };

    const cpu_slot = currentCpuSlot();
    const first_entry = enterLog(cpu_slot);
    defer leaveLog(cpu_slot);

    if (!first_entry) {
        // avoid re-entrant recursive logging corruption
        return;
    }

    const flags = lock.acquire();
    defer lock.release(flags);

    primary(bytes);
}
