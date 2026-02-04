const std = @import("std");

pub const CpuId = u32;

pub const CpuInfo = struct {
    id: CpuId,
    apic_id: u32,
    is_bsp: bool,
    online: bool,
    enabled: bool,
};

pub const ArchSmp = struct {
    initFn: *const fn () anyerror!void,
    getCpuCountFn: *const fn () u32,
    getCurrentCpuIdFn: *const fn () CpuId,
    getCpuInfoFn: *const fn (CpuId) ?*const CpuInfo,
};

var arch_smp: ?ArchSmp = null;

pub fn init(arch_impl: ArchSmp) !void {
    arch_smp = arch_impl;
    try arch_impl.initFn();
}

pub fn getCpuCount() u32 {
    return arch_smp.?.getCpuCountFn();
}

pub fn getCurrentCpuId() CpuId {
    return arch_smp.?.getCurrentCpuIdFn();
}

pub fn getCpuInfo(cpu_id: CpuId) ?*const CpuInfo {
    return arch_smp.?.getCpuInfo(cpu_id);
}
