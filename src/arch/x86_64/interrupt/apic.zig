const std = @import("std");

pub const LocalApic = struct {
    base_address: u64,

    const Register = enum(u32) {
        id = 0x20,
        version = 0x30,
        task_priority = 0x80,
        eoi = 0xb0,
        spurious_interrupt = 0xf0,
        icr_low = 0x300,
        icr_high = 0x310,
        timer_lvt = 0x320,
        lint0_lvt = 0x350,
        lint1_lvt = 0x360,
        error_lvt = 0x370,
        timer_initial_count = 0x380,
        timer_current_count = 0x390,
        timer_divide_config = 0x3e0,
    };

    pub fn init(base_addr: u64) LocalApic {
        return .{ .base_address = base_addr };
    }

    fn read(self: *const LocalApic, reg: Register) u32 {
        const addr = self.base_address + @intFromEnum(reg);
        return @as(*volatile u32, @ptrFromInt(addr)).*;
    }

    fn write(self: *const LocalApic, reg: Register, value: u32) void {
        const addr = self.base_address + @intFromEnum(reg);
        @as(*volatile u32, @ptrFromInt(addr)).* = value;
    }

    pub fn enable(self: *const LocalApic) void {
        const spurious = self.read(.spurious_interrupt);
        self.write(.spurious_interrupt, spurious | 0x1ff);
    }

    pub fn getId(self: *const LocalApic) u8 {
        return @truncate(self.read(.id) >> 24);
    }

    pub fn sendEoi(self: *const LocalApic) void {
        self.write(.eoi, 0);
    }

    pub fn sendIpi(self: *const LocalApic, destination: u8, vector: u8, delivery_mode: DeliveryMode, level: Level, trigger: Trigger) void {
        while ((self.read(.icr_low) & (1 << 12)) != 0) {
            std.atomic.spinLoopHint();
        }

        self.write(.icr_high, @as(u32, destination) << 24);

        var icr_low: u32 = vector;
        icr_low |= @as(u32, @intFromEnum(delivery_mode)) << 8;
        icr_low |= @as(u32, @intFromEnum(level)) << 14;
        icr_low |= @as(u32, @intFromEnum(trigger)) << 15;

        self.write(.icr_low, icr_low);

        while ((self.read(.icr_low) & (1 << 12)) != 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub const DeliveryMode = enum(u3) {
        fixed = 0,
        lowest_priority = 1,
        smi = 2,
        nmi = 4,
        init = 5,
        sipi = 6,
    };

    pub const Level = enum(u1) {
        deassert = 0,
        assert = 1,
    };

    pub const Trigger = enum(u1) {
        edge = 0,
        level = 1,
    };
};

/// Get APIC base address from MSR
pub fn getApicBase() u64 {
    const msr = 0x1b;
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );

    return (@as(u64, high) << 32) | low;
}

/// Set APIC base address
pub fn setApicBase(base: u64) void {
    const msr = 0x1b;
    const low: u32 = @truncate(base);
    const high: u32 = @truncate(base >> 32);

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}
