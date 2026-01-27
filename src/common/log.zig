const std = @import("std");

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
var cpu_id_fn: ?CpuIdFn = null;
var tsc_fn: ?TscFn = null;

// ==================================
// Spinlock (SMP-safe)
// ==================================
var lock: bool = false;

fn acquire() void {
    while (@atomicRmw(bool, &lock, .Xchg, true, .acquire)) {}
}

fn release() void {
    @atomicStore(bool, &lock, false, .release);
}

// =====================================
// Public setup API
// =====================================
pub fn setWriter(w: WriteFn) void {
    write_fn = w;
}

pub fn setCpuId(f: CpuIdFn) void {
    cpu_id_fn = f;
}

pub fn setTscFn(f: TscFn) void {
    tsc_fn = f;
}

// =====================================
// Core logger
// =====================================

fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    // Filter log levels
    if (@intFromEnum(level) > @intFromEnum(LOG_LEVEL)) return;
    // Is backend set??
    if (write_fn == null) return;

    var buf: [1024]u8 = undefined;

    const cpu_id: usize = if (cpu_id_fn) |f| f() else 0;
    const tsc: u64 = if (tsc_fn) |f| f() else 0;

    // Format string:
    // [    TSC][CPUx][LEVEL] message
    const full_fmt =
        "{s}[{d:>12}][CPU{d}][{s}] - " ++ fmt ++ "{s}\n";

    const all_args = .{ level.color().code(), tsc, cpu_id, level.name() } ++ args ++ .{Color.reset.code()};
    const out_str = std.fmt.bufPrint(&buf, full_fmt, all_args) catch return;

    acquire();
    write_fn.?(out_str);
    release();
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
    if (write_fn) |w| {
        acquire();
        w(bytes);
        release();
    }
}
