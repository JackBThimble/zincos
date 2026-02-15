const std = @import("std");
const boot = @import("shared").boot;

const apic = @import("../interrupt/apic.zig");
const idt = @import("../interrupt/idt.zig");
const acpi = @import("../platform/acpi.zig");
const percpu = @import("../cpu/percpu.zig");

const manager = @import("manager.zig");
const topology = @import("topology.zig");
const bringup = @import("bringup.zig");

var active_service: ?*Service = null;

pub const Service = struct {
    cpu_mgr: manager.CpuManager = undefined,
    pub fn init(
        self: *Service,
        allocator: std.mem.Allocator,
        boot_info: *const boot.BootInfo,
    ) !void {
        const tables = try acpi.AcpiTables.init(boot_info.rsdp_address);
        const madt = tables.madt orelse return error.NoMadt;

        apic.initLocal();
        apic.local().enable();

        const cpu_count = try topology.countEnabledCpus(madt);
        self.cpu_mgr = try manager.CpuManager.init(allocator, cpu_count);
        try topology.discoverCpus(&self.cpu_mgr, madt, apic.local().getId());
        try bringup.setupBsp(&self.cpu_mgr);
        active_service = self;
    }

    pub fn bootAps(
        self: *Service,
        allocator: std.mem.Allocator,
    ) !void {
        try bringup.bootAps(&self.cpu_mgr, allocator);
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

pub fn requestResched(target_cpu_id: u32) void {
    const svc = active_service orelse return;
    const cpu = svc.cpu_mgr.getCpu(target_cpu_id) orelse return;
    if (@atomicLoad(u32, &cpu.online, .acquire) == 0) return;
    if (target_cpu_id == percpu.getCpuId()) return;

    apic.local().sendIpi(
        @truncate(cpu.apic_id),
        idt.RESCHED_VECTOR,
        .fixed,
        .assert,
        .edge,
    );
}
