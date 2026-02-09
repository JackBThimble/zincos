const acpi = @import("../platform/acpi.zig");
const manager = @import("manager.zig");

pub fn countEnabledCpus(madt: *const acpi.Madt) !u32 {
    var count: u32 = 0;
    const entries = madt.getEntries();
    var off: usize = 0;

    while (off < entries.len) {
        const hdr = @as(
            *const acpi.Madt.EntryHeader,
            @ptrCast(@alignCast(&entries[off])),
        );

        if (@as(acpi.Madt.EntryType, @enumFromInt(hdr.entry_type)) == .local_apic) {
            const lapic = @as(
                *const acpi.Madt.LocalApic,
                @ptrCast(@alignCast(hdr)),
            );
            if (lapic.isEnabled()) count += 1;
        }

        off += hdr.length;
    }
    if (count == 0) return error.NoCpus;
    return count;
}

pub fn discoverCpus(cpu_mgr: *manager.CpuManager, madt: *const acpi.Madt, bsp_apic_id: u8) !void {
    const entries = madt.getEntries();
    var off: usize = 0;

    while (off < entries.len) {
        const hdr = @as(*const acpi.Madt.EntryHeader, @ptrCast(@alignCast(&entries[off])));

        if (@as(acpi.Madt.EntryType, @enumFromInt(hdr.entry_type)) == .local_apic) {
            const lapic = @as(
                *const acpi.Madt.LocalApic,
                @ptrCast(@alignCast(hdr)),
            );

            if (lapic.isEnabled()) {
                var is_bsp: u8 = 0;
                if (lapic.apic_id == bsp_apic_id) is_bsp = 1;
                _ = try cpu_mgr.allocateCpu(lapic.apic_id, is_bsp);
            }
        }

        off += hdr.length;
    }
}
