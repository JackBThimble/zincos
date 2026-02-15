const std = @import("std");
const apic = @import("apic.zig");
const idt = @import("idt.zig");
const serial = @import("../serial.zig");
const log = @import("shared").log;

// =============================================================================
// Scheduler timer backend:
// - Prefer TSC-deadline mode when CPU guarantees invariant TSC.
// - Fall back to LAPIC one-shot when not available.
// =============================================================================

const PIT_FREQ: u64 = 1193182;
const PIT_CH2_DATA: u16 = 0x42;
const PIT_CMD: u16 = 0x43;
const PIT_CH2_GATE: u16 = 0x61;
const IA32_TSC_DEADLINE: u32 = 0x6e0;

const TimerBackend = enum {
    lapic_one_shot,
    tsc_deadline,
};

const CpuidLeaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

const TscCaps = struct {
    deadline: bool,
    invariant: bool,
};

var ticks_per_ms: u32 = 0;
var tsc_hz: u64 = 0;
var backend: TimerBackend = .lapic_one_shot;

pub fn isCalibrated() bool {
    return ticks_per_ms != 0;
}

pub fn ticksPerMs() u32 {
    return ticks_per_ms;
}

pub fn usingTscDeadline() bool {
    return backend == .tsc_deadline;
}

pub fn calibrate() void {
    log.info("Calibrating APIC timer...", .{});

    const caps = detectTscCaps();
    const calibration_ms: u32 = 10;
    const pit_count: u16 = @intCast((PIT_FREQ * calibration_ms) / 1000);

    var gate = serial.inb(PIT_CH2_GATE);
    gate = (gate & 0xfd) | 0x01;
    serial.outb(PIT_CH2_GATE, gate);

    serial.outb(PIT_CMD, 0xb0);
    serial.outb(PIT_CH2_DATA, @truncate(pit_count));
    serial.outb(PIT_CH2_DATA, @truncate(pit_count >> 8));

    apic.local().timerStartMaskedOneShot(0xffff_ffff, .divide_1);
    const tsc_start = readTscOrdered();

    gate = serial.inb(PIT_CH2_GATE);
    gate &= 0xfe;
    serial.outb(PIT_CH2_GATE, gate);
    gate |= 0x01;
    serial.outb(PIT_CH2_GATE, gate);

    while ((serial.inb(PIT_CH2_GATE) & 0x20) == 0) {
        std.atomic.spinLoopHint();
    }
    const tsc_end = readTscOrdered();

    const remaining = apic.local().read(.timer_current_count);
    apic.local().timerStop();

    const elapsed = 0xffff_ffff - remaining;
    ticks_per_ms = @intCast(elapsed / calibration_ms);
    const measured_hz: u128 = (@as(u128, tsc_end - tsc_start) * 1000) / calibration_ms;
    if (measured_hz > 0 and measured_hz <= std.math.maxInt(u64)) {
        tsc_hz = @intCast(measured_hz);
    }
    if (cpuidTscHz()) |hz| {
        tsc_hz = hz;
    }

    log.info("APIC timer: {} ticks/ms (~{} MHz bus)", .{
        ticks_per_ms,
        ticks_per_ms / 1000,
    });

    if (caps.deadline and caps.invariant and tsc_hz != 0) {
        backend = .tsc_deadline;
        log.info("Timer backend: TSC-deadline ({} MHz)", .{tsc_hz / 1_000_000});
        return;
    }

    backend = .lapic_one_shot;
    if (!caps.deadline) {
        log.info("Timer backend: APIC one-shot (TSC-deadline unsupported)", .{});
    } else if (!caps.invariant) {
        log.warn("Timer backend: APIC one-shot (non-invariant TSC)", .{});
    } else {
        log.warn("Timer backend: APIC one-shot (could not determine TSC frequency)", .{});
    }
}

fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn detectTscCaps() TscCaps {
    const leaf1 = cpuid(0x1, 0);
    const max_ext = cpuid(0x8000_0000, 0).eax;

    var invariant = false;
    if (max_ext >= 0x8000_0007) {
        const ext7 = cpuid(0x8000_0007, 0);
        invariant = (ext7.edx & (1 << 8)) != 0;
    }

    return .{
        .deadline = (leaf1.ecx & (1 << 24)) != 0,
        .invariant = invariant,
    };
}

fn cpuidTscHz() ?u64 {
    const max_basic = cpuid(0x0, 0).eax;

    if (max_basic >= 0x15) {
        const leaf15 = cpuid(0x15, 0);
        if (leaf15.eax != 0 and leaf15.ebx != 0 and leaf15.ecx != 0) {
            const hz: u128 = (@as(u128, leaf15.ecx) * leaf15.ebx) / leaf15.eax;
            if (hz > 0 and hz <= std.math.maxInt(u64)) {
                return @intCast(hz);
            }
        }
    }

    if (max_basic >= 0x16) {
        const leaf16 = cpuid(0x16, 0);
        if (leaf16.eax != 0) {
            return @as(u64, leaf16.eax) * 1_000_000;
        }
    }

    return null;
}

fn readTscOrdered() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile (
        \\lfence
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

fn nsToTicks(delay_ns: u64) u32 {
    if (ticks_per_ms == 0) {
        return 0;
    }

    const scaled: u128 = (@as(u128, delay_ns) * ticks_per_ms + 999_999) / 1_000_000;
    var ticks: u128 = scaled;
    if (ticks == 0) ticks = 1;
    if (ticks > std.math.maxInt(u32)) ticks = std.math.maxInt(u32);
    return @intCast(ticks);
}

fn nsToTscCycles(delay_ns: u64) u64 {
    if (tsc_hz == 0) {
        return 0;
    }

    const scaled: u128 = (@as(u128, delay_ns) * tsc_hz + 999_999_999) / 1_000_000_000;
    var cycles: u128 = scaled;
    if (cycles == 0) cycles = 1;
    if (cycles > std.math.maxInt(u64)) cycles = std.math.maxInt(u64);
    return @intCast(cycles);
}

fn armLapicOneShotNs(delay_ns: u64) void {
    if (ticks_per_ms == 0) {
        log.err("APIC timer used before calibration", .{});
        return;
    }

    var lapic = apic.local();
    lapic.timerStartOneShot(
        nsToTicks(delay_ns),
        .divide_1,
        idt.TIMER_VECTOR,
    );
}

fn armTscDeadlineNs(delay_ns: u64) void {
    if (tsc_hz == 0) {
        log.err("TSC deadline timer used before calibration", .{});
        return;
    }

    const now = readTscOrdered();
    const delta = nsToTscCycles(delay_ns);
    const deadline = if (std.math.maxInt(u64) - now < delta)
        std.math.maxInt(u64)
    else
        now + delta;

    var lapic = apic.local();
    lapic.write(.timer_lvt, (@as(u32, 0x2) << 17) | @as(u32, idt.TIMER_VECTOR));
    writeMsr(IA32_TSC_DEADLINE, deadline);
}

pub fn armOneShotNs(delay_ns: u64) void {
    switch (backend) {
        .lapic_one_shot => armLapicOneShotNs(delay_ns),
        .tsc_deadline => armTscDeadlineNs(delay_ns),
    }
}

pub fn armOneShotUs(delay_us: u64) void {
    armOneShotNs(delay_us * 1000);
}

pub fn armOneShotMs(delay_ms: u64) void {
    armOneShotNs(delay_ms * 1_000_000);
}

pub fn disarm() void {
    if (backend == .tsc_deadline) {
        var lapic_tsc = apic.local();
        writeMsr(IA32_TSC_DEADLINE, 0);
        lapic_tsc.write(.timer_lvt, (1 << 16) | (@as(u32, 0x2) << 17) | @as(u32, idt.TIMER_VECTOR));
        return;
    }

    var lapic = apic.local();
    lapic.timerStop();
    lapic.write(.timer_lvt, (1 << 16) | @as(u32, idt.TIMER_VECTOR));
}

pub fn deadlineAfterMs(ms: u64) u64 {
    if (tsc_hz == 0) return 0;
    const now = readTscOrdered();
    const delta: u128 = (@as(u128, ms) * tsc_hz + 999) / 1000;
    const d: u64 = @intCast(@min(delta, std.math.maxInt(u64)));
    return if (std.math.maxInt(u64) - now < d) std.math.maxInt(u64) else now + d;
}

pub fn deadlinePassed(deadline_tsc: u64) bool {
    if (deadline_tsc == 0) return true;
    return readTscOrdered() >= deadline_tsc;
}

pub fn busyWaitUs(us: u64) void {
    if (tsc_hz == 0) return;
    const start = readTscOrdered();
    const delta: u128 = (@as(u128, us) * tsc_hz + 999_999) / 1_000_000;
    const d: u64 = @intCast(@min(delta, std.math.maxInt(u64)));
    while (readTscOrdered() - start < d) std.atomic.spinLoopHint();
}

pub fn busyWaitMs(ms: u64) void {
    busyWaitUs(ms * 1000);
}
