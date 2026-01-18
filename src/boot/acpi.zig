const std = @import("std");
const uefi = std.os.uefi;
const Guid = uefi.Guid;

const console = @import("console.zig");

const acpi_20_guid = uefi.tables.ConfigurationTable.acpi_20_table_guid;
const acpi_10_guid = uefi.tables.ConfigurationTable.acpi_10_table_guid;

pub fn find_rsdp() ?u64 {
    console.println("[*] Searching for ACPI RSDP...");

    const config_entries = uefi.system_table.configuration_table[0..uefi.system_table.number_of_table_entries];

    // Search configuration tables

    for (config_entries) |entry| {
        if (entry.vendor_guid.eql(acpi_20_guid) or entry.vendor_guid.eql(acpi_10_guid)) {
            const rsdp_addr = @intFromPtr(entry.vendor_table);
            console.printfln("[+] RSDP found at 0x{x}", .{rsdp_addr});
            return rsdp_addr;
        }
    }

    console.println("[!] RSDP not found - ACPI may not be available");
    return null;
}
