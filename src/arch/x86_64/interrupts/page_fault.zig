const std = @import("std");
const serial = @import("../serial.zig");
const common = @import("common");

// =================================
// Page Table Entry Flags
// =================================
pub const PTE_PRESENT = @as(u64, 1) << 0;
pub const PTE_WRITABLE = @as(u64, 1) << 1;
pub const PTE_USER = @as(u64, 1) << 2;
pub const PTE_WRITE_THROUGH = @as(u64, 1) << 3;
pub const PTE_CACHE_DISABLE = @as(u64, 1) << 4;
pub const PTE_ACCESSED = @as(u64, 1) << 5;
pub const PTE_DIRTY = @as(u64, 1) << 6;
pub const PTE_HUGE = @as(u64, 1) << 7; // for PD/PT entries
pub const PTE_GLOBAL = @as(u64, 1) << 8;
pub const PTE_PAT = @as(u64, 1) << 11;
pub const PTE_NX = @as(u64, 1) << 63;

// mask for physical address
pub const PTE_ADDR_MASK = 0x000f_ffff_ffff_f000;

pub fn handlePageFault(err: u64, rip: u64, cs: u64, rsp: u64, ss: u64, rflags: u64) noreturn {
    const cr2 = readCr2();

    serial.println("\n=== #PF Page Fault ===\n");

    serial.printfln("CR2    = 0x{x}", .{cr2});
    serial.printfln("RIP    = 0x{x}", .{rip});
    serial.printfln("RSP    = 0x{x}", .{rsp});
    serial.printfln("RFLAGS = 0x{x}", .{rflags});
    serial.printfln("CS     = 0x{x}", .{cs});
    serial.printfln("SS     = 0x{x}", .{ss});
    serial.printfln("ERR    = 0x{x}", .{err});

    // Decode error code
    // bit0 P: 0=non-present, 1=protection violation
    // bit1 W/R: 0=read, 1=write
    // bit2 U/S: 0=kernel, 1=user
    // bit3 RSVD: reserved
    // bit4 I/D: 0=instruction fetch, 1=data access
    // bit5 PVI: page-level protection violation
    // bit6 RSVD: reserved
    // bit7 RSVD: reserved
    const error_code = err;
    const present = (error_code & (1 << 0)) != 0;
    const write = (error_code & (1 << 1)) != 0;
    const user = (error_code & (1 << 2)) != 0;
    const rsvd = (error_code & (1 << 3)) != 0;
    const ifetch = (error_code & (1 << 4)) != 0;
    const page_level_protection_violation = (error_code & (1 << 5)) != 0;
    const reserved = (error_code & (1 << 6)) != 0;
    const reserved2 = (error_code & (1 << 7)) != 0;

    serial.printfln("Present = {any}", .{present});
    serial.printfln("Write   = {any}", .{write});
    serial.printfln("User    = {any}", .{user});
    serial.printfln("Reserved = {any}", .{rsvd});
    serial.printfln("Instruction Fetch = {any}", .{ifetch});
    serial.printfln("Page Level Protection Violation = {any}", .{page_level_protection_violation});
    serial.printfln("Reserved2 = {any}", .{reserved});
    serial.printfln("Reserved3 = {any}", .{reserved2});

    dumpPageWalk(cr2);

    serial.println("Halting.");
    while (true) asm volatile ("cli; hlt");
}

fn readCr2() u64 {
    var v: u64 = 0;
    asm volatile ("mov %%cr2, %[x]"
        : [x] "=r" (v),
        :
        : .{});
    return v;
}

fn dumpPageWalk(virt: u64) void {
    serial.printfln("\n--- Page walk for VA 0x{x}", .{virt});

    const cr3 = readCr3() & ~@as(u64, 0xfff);
    serial.printfln("CR3 = 0x{x}", .{cr3});

    const pml4e = readEntry("PML4", cr3, (virt >> 39) & 0x1ff) orelse return;
    const pdpt_phys = pml4e & PTE_ADDR_MASK;

    const pdpte = readEntry("PDPT", pdpt_phys, (virt >> 30) & 0x1ff) orelse return;
    if ((pdpte & PTE_HUGE) != 0) {
        serial.printfln("PDPT huge (1GiB) entry.", .{});
        return;
    }
    const pd_phys = pdpte & PTE_ADDR_MASK;

    const pde = readEntry("PD", pd_phys, (virt >> 21) & 0x1ff) orelse return;
    if ((pde & PTE_HUGE) != 0) {
        serial.printfln("PD huge (2MiB) entry.\n", .{});
        return;
    }
    const pt_phys = pde & PTE_ADDR_MASK;

    _ = readEntry("PT", pt_phys, (virt >> 12) & 0x1ff) orelse return;
}

fn readEntry(level: []const u8, table_phys: u64, index: u64) ?u64 {
    const table_virt = table_phys + common.g_boot_info.?.hhdm_base;
    const tbl: [*]const u64 = @ptrFromInt(@as(usize, @intCast(table_virt)));
    const e = tbl[@as(usize, @intCast(index))];

    serial.printfln("{s}[{d}] = 0x{x} ({s})", .{
        level,
        index,
        e,
        flagStr(e),
    });

    if ((e & PTE_PRESENT) == 0) {
        serial.printfln(" -> not present\n", .{});
        return null;
    }
    return e;
}

fn flagStr(e: u64) []const u8 {
    _ = e;

    return "see bits";
}

fn levelFromIndex(index: u64) []const u8 {
    const levels = [_][]const u8{ "PML4", "PDPT", "PD", "PT" };
    return levels[@as(usize, @intCast(index))];
}

fn readCr3() u64 {
    var cr3: u64 = 0;
    asm volatile ("mov %%cr3, %[x]"
        : [x] "=r" (cr3),
        :
        : .{});
    return cr3;
}
