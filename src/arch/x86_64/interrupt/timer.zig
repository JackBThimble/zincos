const std = @import("std");
const apic = @import("apic.zig");
const idt = @import("idt.zig");
const serial = @import("../serial.zig");
const log = @import("shared").log;

// =============================================================================
// APIC Timer - calibrate against PIT, then run periodic
// =============================================================================

const PIT_FREQ: u64 = 1193182;
const PIT_CH2_DATA: u16 = 0x42;
const PIT_CMD: u16 = 0x43;
const PIT_CH2_GATE: u16 = 0x61;

pub const TICK_HZ: u32 = 1000;

var ticks_per_ms: u32 = 0;

pub fn calibrate(lapic: *const apic.LocalApic) void {
    log.info("Calibrating APIC timer...", .{});

    const calibration_ms: u32 = 10;
    const pit_count: u16 = @intCast((PIT_FREQ * calibration_ms) / 1000);

    var gate = serial.inb(PIT_CH2_GATE);
    gate = (gate & 0xfd) | 0x01;
    serial.outb(PIT_CH2_GATE, gate);

    serial.outb(PIT_CMD, 0xb0);
    serial.outb(PIT_CH2_DATA, @truncate(pit_count));
    serial.outb(PIT_CH2_DATA, @truncate(pit_count >> 8));

    lapic.timerStartMaskedOneShot(0xffff_ffff, .divide_1);

    gate = serial.inb(PIT_CH2_GATE);
    gate &= 0xfe;
    serial.outb(PIT_CH2_GATE, gate);
    gate |= 0x01;
    serial.outb(PIT_CH2_GATE, gate);

    while ((serial.inb(PIT_CH2_GATE) & 0x20) == 0) {
        std.atomic.spinLoopHint();
    }

    const remaining = lapic.read(.timer_current_count);
    lapic.timerStop();

    const elapsed = 0xffff_ffff - remaining;
    ticks_per_ms = @intCast(elapsed / calibration_ms);

    log.info("APIC timer: {} ticks/ms (~{} MHz bus)", .{
        ticks_per_ms,
        ticks_per_ms / 1000,
    });
}

pub fn startPeriodic(lapic: *const apic.LocalApic) void {
    if (ticks_per_ms == 0) {
        log.err("APIC timer not calibrated!", .{});
        return;
    }

    const count: u32 = ticks_per_ms * (1000 / TICK_HZ);

    const lvt: u32 = idt.TIMER_VECTOR | (1 << 17);
    lapic.write(.timer_lvt, lvt);
    lapic.write(.timer_divide_config, @intFromEnum(apic.LocalApic.TimerDivide.divide_1));
    lapic.write(.timer_initial_count, count);

    log.info("APIC timer started: {} Hz (count={})", .{ TICK_HZ, count });
}

pub fn stop(lapic: *const apic.LocalApic) void {
    lapic.timerStop();
    lapic.write(.timer_lvt, (1 << 16));
}
