// mp_services.zig
const std = @import("std");
const uefi = std.os.uefi;

/// EFI_MP_SERVICES_PROTOCOL GUID
/// 3fdda605-a76e-4f46-ad29-12267d037f1b
pub const EFI_MP_SERVICES_PROTOCOL_GUID = uefi.Guid{
    .time_low = 0x3fdda605,
    .time_mid = 0xa76e,
    .time_high_and_version = 0x4f46,
    .clock_seq_high_and_reserved = 0xad,
    .clock_seq_low = 0x29,
    .node = [_]u8{ 0x12, 0xf4, 0x53, 0x1b, 0x3d, 0x08 },
};

pub const Status = uefi.Status;

/// StatusFlag bits (UEFI spec)
pub const EFI_PROCESSOR_ENABLED: u32 = 1 << 0;
pub const EFI_PROCESSOR_BSP: u32 = 1 << 1;
// other bits exist (healthy, etc) but you usually don't need them yet.

pub const ProcessorInfo = extern struct {
    processor_id: u64, // x86: APIC ID (or x2APIC ID); arm: MPIDR-ish
    status_flag: u32, // EFI_PROCESSOR_* bits
    location: u32, // package/core/thread info encoding (optional)
};

pub const MpServicesProtocol = extern struct {
    GetNumberOfProcessors: *const fn (
        self: *MpServicesProtocol,
        number_of_processors: *usize,
        number_of_enabled_processors: *usize,
    ) callconv(.c) Status,

    GetProcessorInfo: *const fn (
        self: *MpServicesProtocol,
        processor_number: usize,
        processor_info: *ProcessorInfo,
    ) callconv(.c) Status,

    // The protocol has more funcs (StartupAllAPs, StartupThisAP, etc),
    // but you don't need them just to count/identify CPUs.
};

pub const CpuDesc = struct {
    processor_number: usize,
    processor_id: u64,
    enabled: bool,
    bsp: bool,
};

pub const CpuSummary = struct {
    total: usize,
    enabled: usize,
    bsp_processor_number: ?usize,
};

/// Locate the MP Services protocol. Returns null if firmware doesn't provide it.
pub fn locate(bs: *uefi.tables.BootServices) ?*MpServicesProtocol {
    var out: *MpServicesProtocol = undefined;

    // LocateProtocol takes (protocol GUID, registration, interface**)
    const st = bs._locateProtocol(
        &EFI_MP_SERVICES_PROTOCOL_GUID,
        null,
        @ptrCast(&out),
    );

    if (st != .success) return null;
    return out;
}

/// Get total + enabled CPU counts and BSP processor number (index in MP services numbering).
pub fn getSummary(mp: *MpServicesProtocol) !CpuSummary {
    var total: usize = 0;
    var enabled: usize = 0;

    const st = mp.GetNumberOfProcessors(mp, &total, &enabled);
    if (st != .success) return error.MpGetNumberFailed;

    // Determine BSP processor number by scanning ProcessorInfo.
    var bsp_num: ?usize = null;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var info: ProcessorInfo = undefined;
        const st2 = mp.GetProcessorInfo(mp, i, &info);
        if (st2 != .success) return error.MpGetProcessorInfoFailed;

        if ((info.status_flag & EFI_PROCESSOR_BSP) != 0) {
            bsp_num = i;
            break;
        }
    }

    return .{
        .total = total,
        .enabled = enabled,
        .bsp_processor_number = bsp_num,
    };
}

/// Enumerate CPUs. If `only_enabled` is true, returns only enabled CPUs.
pub fn enumerate(
    allocator: std.mem.Allocator,
    mp: *MpServicesProtocol,
    only_enabled: bool,
) ![]CpuDesc {
    var total: usize = 0;
    var enabled: usize = 0;

    const st = mp.GetNumberOfProcessors(mp, &total, &enabled);
    if (st != .success) return error.MpGetNumberFailed;

    // Worst-case allocate for total (simpler).
    var tmp = try allocator.alloc(CpuDesc, total);
    errdefer allocator.free(tmp);

    var out_len: usize = 0;

    var i: usize = 0;
    while (i < total) : (i += 1) {
        var info: ProcessorInfo = undefined;
        const st2 = mp.GetProcessorInfo(mp, i, &info);
        if (st2 != .success) return error.MpGetProcessorInfoFailed;

        const is_enabled = (info.status_flag & EFI_PROCESSOR_ENABLED) != 0;
        const is_bsp = (info.status_flag & EFI_PROCESSOR_BSP) != 0;

        if (only_enabled and !is_enabled) continue;

        tmp[out_len] = .{
            .processor_number = i,
            .processor_id = info.processor_id,
            .enabled = is_enabled,
            .bsp = is_bsp,
        };
        out_len += 1;
    }

    // Shrink to fit.
    return allocator.realloc(tmp, out_len);
}

/// Convenience: get enabled processor IDs as u64.
/// (x86: APIC/x2APIC IDs; arm: MPIDR-ish)
pub fn enabledProcessorIds(
    allocator: std.mem.Allocator,
    mp: *MpServicesProtocol,
) ![]u64 {
    const cpus = try enumerate(allocator, mp, true);
    defer allocator.free(cpus);

    var ids = try allocator.alloc(u64, cpus.len);
    var i: usize = 0;
    while (i < cpus.len) : (i += 1) {
        ids[i] = cpus[i].processor_id;
    }
    return ids;
}
