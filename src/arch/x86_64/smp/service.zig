const std = @import("std");
const boot = @import("shared").boot;

const apic = @import("../interrupt/apic.zig");
const acpi = @import("../platform/acpi.zig");
const percpu = @import("../cpu/percpu.zig");

const manager = @import("manager.zig");
const topology = @import("topology.zig");
const bringup = @import("bringup.zig");

pub const Service = struct {
    lapic: apic.LocalApic = undefined,
    cpu_mgr: manager.CpuManager = undefined,
    pub fn init(
        self: *Service,
        allocator: std.mem.Allocator,
        boot_info: *const boot.BootInfo,
    ) !void {
        const tables = try acpi.AcpiTables.init(boot_info.rsdp_address);
        const madt = tables.madt orelse return error.NoMadt;

        const apic_base = apic.getApicBase() & ~@as(u64, 0xfff);
        self.lapic = apic.LocalApic.init(apic_base);
        self.lapic.enable();

        const cpu_count = try topology.countEnabledCpus(madt);
        self.cpu_mgr = try manager.CpuManager.init(allocator, cpu_count);
        try topology.discoverCpus(&self.cpu_mgr, madt, self.lapic.getId());
        try bringup.setupBsp(&self.cpu_mgr);
    }

    pub fn bootAps(
        self: *Service,
        allocator: std.mem.Allocator,
    ) !void {
        try bringup.bootAps(&self.lapic, &self.cpu_mgr, allocator);
        try self.cpu_mgr.waitForOnline(self.cpu_mgr.cpu_count, 2000);
    }

    pub fn getCpuCount(self: *const Service) u32 {
        return self.cpu_mgr.cpu_count;
    }

    pub fn getCurrentCpuId(self: *const Service) u32 {
        _ = self;
        return percpu.getCpuId();
    }
};
