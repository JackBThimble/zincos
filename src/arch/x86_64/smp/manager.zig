const std = @import("std");
const percpu = @import("../cpu/percpu.zig");
const PerCpu = percpu.PerCpu;
const timer = @import("../interrupt/timer.zig");

pub const CpuManager = struct {
    allocator: std.mem.Allocator,
    cpus: []?*PerCpu,
    cpu_count: u32,
    online_count: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, max_cpus: u32) !CpuManager {
        const cpus = try allocator.alloc(?*PerCpu, max_cpus);
        @memset(cpus, null);

        return .{
            .allocator = allocator,
            .cpus = cpus,
            .cpu_count = 0,
            .online_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn allocateCpu(self: *CpuManager, apic_id: u32, is_bsp: bool) !*PerCpu {
        if (self.cpu_count >= self.cpus.len) return error.TooManyCpus;

        const cpu = try self.allocator.create(PerCpu);

        cpu.* = .{
            .cpu_id = self.cpu_count,
            .apic_id = apic_id,
            .is_bsp = is_bsp,
            .online = std.atomic.Value(bool).init(false),
            .kernel_stack = 0,
            .current_task = null,
            .tss = std.mem.zeroes(PerCpu.Tss),
            .gdt = PerCpu.Gdt.init(),
            .scratch0 = 0,
            .scratch1 = 0,
            .alloc_count = 0,
            .free_count = 0,
        };

        self.cpus[self.cpu_count] = cpu;
        self.cpu_count += 1;

        return cpu;
    }

    pub fn getCpu(self: *const CpuManager, cpu_id: u32) ?*PerCpu {
        if (cpu_id >= self.cpu_count) return null;
        return self.cpus[cpu_id];
    }

    pub fn getCpuByApicId(self: *const CpuManager, apic_id: u32) ?*PerCpu {
        for (0..self.cpu_count) |i| {
            const cpu = self.cpus[i] orelse continue;
            if (cpu.apic_id == apic_id) return cpu;
        }
        return null;
    }

    pub fn getBsp(self: *const CpuManager) ?*PerCpu {
        for (0..self.cpu_count) |i| {
            const cpu = self.cpus[i] orelse continue;
            if (cpu.is_bsp) return cpu;
        }
        return null;
    }

    pub fn markOnline(self: *CpuManager, cpu: *PerCpu) void {
        cpu.online.store(true, .release);
        _ = self.online_count.fetchAdd(1, .acq_rel);
    }

    pub fn waitForOnline(self: *const CpuManager, target_count: u32, timeout_ms: u64) !void {
        const deadline = timer.deadlineAfterMs(timeout_ms);
        while (self.online_count.load(.acquire) < target_count) {
            if (timer.deadlinePassed(deadline)) return error.Timeout;
            std.atomic.spinLoopHint();
        }
    }
};
