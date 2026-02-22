const arch = @import("../mod.zig");
const log = @import("shared").log;
const acpi = @import("../platform/acpi.zig");

const MAX_OVERRIDES = 16;

const Override = struct {
    source: u8,
    gsi: u32,
    flags: u16,
};

var io_apic: ?IoApic = null;
var overrides: [MAX_OVERRIDES]Override = undefined;
var override_count: usize = 0;

pub const IoApic = struct {
    base: u64, // virtual (HHDM-mapped) base address
    gsi_base: u32,

    fn read(self: *const IoApic, reg: u32) u32 {
        const sel: *volatile u32 = @ptrFromInt(self.base);
        const win: *volatile u32 = @ptrFromInt(self.base + 0x10);
        sel.* = reg;
        return win.*;
    }
    fn write(self: *const IoApic, reg: u32, val: u32) void {
        const sel: *volatile u32 = @ptrFromInt(self.base);
        const win: *volatile u32 = @ptrFromInt(self.base + 0x10);
        sel.* = reg;
        win.* = val;
    }

    pub fn maxRedirectionEntry(self: *const IoApic) u8 {
        return @truncate((self.read(0x01) >> 16) & 0xff);
    }

    /// Route a GSI to a vector on a destination LAPIC.
    /// `flags` encodes polarity (bits 0-1) and trigger mode (bits 2-3)
    /// per the ACPI interrupt source override convention.
    pub fn routeIrq(
        self: *const IoApic,
        gsi: u8,
        vector: u8,
        dest_apic_id: u8,
        flags: u16,
    ) void {
        const reg_low: u32 = 0x10 + @as(u32, gsi) * 2;
        const reg_high: u32 = reg_low + 1;

        // Delivery mode = Fixed, Destination mode = Physical
        var low: u32 = @as(u32, vector);

        // Polarity: bits 0-1 (0b11 = active low)
        if ((flags & 0x3) == 0x3) {
            low |= (1 << 13); // active low
        }

        // Trigger mode: bits 2-3 (0b11 = level triggered)
        if (((flags >> 2) & 0x3) == 0x3) {
            low |= (1 << 15); // level triggered
        }

        const high: u32 = @as(u32, dest_apic_id) << 24;

        self.write(reg_low, low);
        self.write(reg_high, high);
    }

    pub fn maskAll(self: *const IoApic) void {
        const max: u32 = @as(u32, self.maxRedirectionEntry()) + 1;
        for (0..max) |i| {
            const reg: u32 = 0x10 + @as(u32, @intCast(i)) * 2;
            const low = self.read(reg);
            self.write(reg, low | (1 << 16));
        }
    }
};

/// Resolve ISA IRQ to GSI, accounting for interrupt source overrides
fn irqToGsi(irq: u8) struct { gsi: u8, flags: u16 } {
    for (overrides[0..override_count]) |ov| {
        if (ov.source == irq) return .{
            .gsi = @truncate(ov.gsi),
            .flags = ov.flags,
        };
    }
    // Identity mapping, default ISA: edge-triggered, active high
    return .{ .gsi = irq, .flags = 0 };
}

pub fn init(rsdp_address: u64) void {
    const tables = acpi.AcpiTables.init(rsdp_address) catch {
        log.warn("I/O APIC: failed to parse ACPI tables", .{});
        return;
    };
    const madt = tables.madt orelse {
        log.warn("I/O APIC: no MADT found", .{});
        return;
    };

    const entries = madt.getEntries();
    var off: usize = 0;

    while (off < entries.len) {
        const hdr = @as(
            *const acpi.Madt.EntryHeader,
            @ptrCast(@alignCast(&entries[off])),
        );

        switch (@as(acpi.Madt.EntryType, @enumFromInt(hdr.entry_type))) {
            .io_apic => {
                if (io_apic == null) {
                    const entry: *align(1) const acpi.Madt.IoApic = @ptrCast(hdr);
                    io_apic = .{
                        .base = arch.physToVirt(@as(u64, entry.io_apic_address)),
                        .gsi_base = entry.global_system_interrupt_base,
                    };
                    log.info("I/O APIC: addr=0x{x} GSI base={}", .{
                        entry.io_apic_address,
                        entry.global_system_interrupt_base,
                    });
                }
            },
            .interrupt_override => {
                if (override_count < MAX_OVERRIDES) {
                    const ov: *align(1) const acpi.Madt.InterruptOverride = @ptrCast(hdr);
                    overrides[override_count] = .{
                        .source = ov.source,
                        .gsi = ov.gsi,
                        .flags = ov.flags,
                    };
                    log.info("IRQ override: ISA {} -> GSI {} flags=0x{x}", .{
                        ov.source, ov.gsi, ov.flags,
                    });
                    override_count += 1;
                }
            },
            else => {},
        }
        off += hdr.length;
    }

    if (io_apic) |*ioa| {
        ioa.maskAll();
        log.info("I/O APIC initialized: {} entries, {} overrides", .{
            @as(u32, ioa.maxRedirectionEntry()) + 1,
            override_count,
        });
    } else {
        log.warn("No I/O APIC found in MADT", .{});
    }
}

/// Route an ISA IRQ to an IDT vector on a specific LAPIC,
/// resolving any interrupt source overrides from the MADT.
pub fn routeIrq(irq: u8, vector: u8, dest_apic_id: u8) void {
    const ioa = &(io_apic orelse {
        log.warn("routeIrq: no I/O APIC initialized", .{});
        return;
    });
    const resolved = irqToGsi(irq);
    ioa.routeIrq(resolved.gsi, vector, dest_apic_id, resolved.flags);
    log.info("Routed IRQ {} (GSI {}) -> vector {} on LAPIC {}", .{
        irq, resolved.gsi, vector, dest_apic_id,
    });
}
