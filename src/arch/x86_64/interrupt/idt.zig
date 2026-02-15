const std = @import("std");
const log = @import("shared").log;
const apic = @import("apic.zig");

// =============================================================================
// x86_64 Interrupt Descriptor Table
// =============================================================================

const IDT_ENTRIES = 256;

const GateType = enum(u4) {
    interrupt = 0xe,
    trap = 0xf,
};

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    _reserved0: u5 = 0,
    gate_type: u4,
    _zero: u1 = 0,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    _reserved1: u32 = 0,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

var idt: [IDT_ENTRIES]IdtEntry = [_]IdtEntry{std.mem.zeroes(IdtEntry)} ** IDT_ENTRIES;

pub const TIMER_VECTOR: u8 = 32;
pub const RESCHED_VECTOR: u8 = 33;
pub const SPURIOUS_VECTOR: u8 = 0xff;

pub const InterruptFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

extern const isr_stub_table: [IDT_ENTRIES]usize;

// =============================================================================
// Scheduler hooks - function pointers, set once by kernel main.
// =============================================================================
const TickFn = *const fn () void;
const NeedsReschedFn = *const fn () bool;
const ScheduleFn = *const fn () void;
const RequestReschedFn = *const fn () void;

var tick_fn: ?TickFn = null;
var needs_resched_fn: ?NeedsReschedFn = null;
var schedule_fn: ?ScheduleFn = null;
var request_resched_fn: ?RequestReschedFn = null;

pub fn installSchedHooks(
    tick: TickFn,
    needs_resched: NeedsReschedFn,
    sched: ScheduleFn,
    request_resched: RequestReschedFn,
) void {
    tick_fn = tick;
    needs_resched_fn = needs_resched;
    schedule_fn = sched;
    request_resched_fn = request_resched;
}

// =============================================================================
// Init
// =============================================================================
pub fn init() void {
    for (0..IDT_ENTRIES) |i| {
        setGate(@intCast(i), isr_stub_table[i], .interrupt, 0, 0);
    }
    log.info("IDT initialized: {} entries", .{IDT_ENTRIES});
    load();
}

pub fn load() void {
    const limit: u16 = @intCast(@sizeOf(@TypeOf(idt)) - 1);
    const base: u64 = @intFromPtr(&idt);

    if (!isCanonical(base)) @panic("IDT base non-canonical");
    if ((base & 0x7) != 0) @panic("IDT base not 8-byte aligned");

    var idtr: [10]u8 = undefined;
    idtr[0] = @truncate(limit);
    idtr[1] = @truncate(limit >> 8);
    inline for (0..8) |i| {
        idtr[2 + i] = @truncate(base >> @intCast(i * 8));
    }

    asm volatile ("lidtq (%[ptr])"
        :
        : [ptr] "r" (&idtr[0]),
        : .{ .memory = true });
    log.info("IDT loaded: {} entries", .{IDT_ENTRIES});
}

fn isCanonical(va: u64) bool {
    const top = va >> 48;
    return top == 0 or top == 0xffff;
}

pub fn setGate(vector: u8, handler_addr: usize, gate_type: GateType, dpl: u2, ist: u3) void {
    const addr: u64 = @intCast(handler_addr);
    idt[vector] = IdtEntry{
        .offset_low = @truncate(addr),
        .selector = 0x08,
        .ist = ist,
        .gate_type = @intFromEnum(gate_type),
        .dpl = dpl,
        .present = 1,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
    };
}

// =============================================================================
// Dispatch
// =============================================================================

pub export fn interrupt_dispatch(frame: *InterruptFrame) callconv(.c) void {
    const vec: u8 = @truncate(frame.vector);

    switch (vec) {
        0...31 => handleException(frame),
        TIMER_VECTOR => handleTimer(),
        RESCHED_VECTOR => handleResched(),
        SPURIOUS_VECTOR => {},
        else => {
            log.warn("Unhandled interrupt vector {}", .{vec});
            sendEoi();
        },
    }
}

pub export fn sched_check_preempt() callconv(.c) void {
    const needs = needs_resched_fn orelse return;
    const do_sched = schedule_fn orelse return;
    if (needs()) do_sched();
}

fn handleException(frame: *const InterruptFrame) void {
    const vec: u8 = @truncate(frame.vector);
    const names = [_][]const u8{
        "#DE", "#DB", "NMI", "#BP", "#OF", "#BR", "#UD", "#NM",
        "#DF", "??",  "#TS", "#NP", "#SS", "#GP", "#PF", "??",
        "#MF", "#AC", "#MC", "#XM", "#VE", "#CP", "??",  "??",
        "??",  "??",  "??",  "??",  "#HV", "#VC", "#SX", "??",
    };
    const name = if (vec < names.len) names[vec] else "??";

    log.err("CPU EXCEPTION: {s} (vec={}) err=0x{x}", .{
        name, vec, frame.error_code,
    });
    log.err("   RIP=0x{x} CS=0x{x} RFLAGS=0x{x}", .{ frame.rip, frame.cs, frame.rflags });
    log.err("   RSP=0x{x} RAX=0x{x} RBX = 0x{x}", .{ frame.rsp, frame.rax, frame.rbx });

    if (vec == 14) {
        var cr2: u64 = undefined;
        asm volatile ("movq %%cr2, %[cr2]"
            : [cr2] "=r" (cr2),
        );
        log.err("   CR2=0x{x}", .{cr2});
    }

    @panic("Unhandled CPU exception");
}

fn handleTimer() void {
    if (tick_fn) |f| f();
    sendEoi();
}

fn handleResched() void {
    if (request_resched_fn) |f| f();
    sendEoi();
}

fn sendEoi() void {
    apic.local().sendEoi();
}
