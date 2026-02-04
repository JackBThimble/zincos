const std = @import("std");

pub const RsdpDescriptor = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,

    length: u32,
    xsdt_address: u64,
    extended_checksum: u8,
    reserved: [3]u8,

    pub fn validate(self: *const RsdpDescriptor) bool {
        if (!std.mem.eql(u8, &self.signature, "RSD PTR ")) {
            return false;
        }

        var sum: u8 = 0;
        const bytes = @as([*]const u8, @ptrCast(self))[0..20];
        for (bytes) |byte| {
            sum +%= byte;
        }

        return sum == 0;
    }
};

pub const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,

    pub fn validate(self: *const SdtHeader) bool {
        const bytes = @as([*]const u8, @ptrCast(self))[0..self.length];
        var sum: u8 = 0;
        for (bytes) |byte| {
            sum +%= byte;
        }
        return sum == 0;
    }
};

pub const Madt = extern struct {
    header: SdtHeader,
    local_apic_address: u32,
    flags: u32,

    pub const EntryType = enum(u8) {
        local_apic = 0,
        io_apic = 1,
        interrupt_override = 2,
        nmi = 4,
        local_apic_override = 5,
        _,
    };

    pub const EntryHeader = extern struct {
        entry_type: u8,
        length: u8,
    };

    pub const LocalApic = extern struct {
        header: EntryHeader,
        acpi_processor_id: u8,
        apic_id: u8,
        flags: u32,

        pub fn isEnabled(self: *const LocalApic) bool {
            return (self.flags & 0x1) != 0;
        }
    };

    pub const IoApic = extern struct {
        header: EntryHeader,
        io_apic_id: u8,
        reserved: u8,
        io_apic_address: u32,
        global_system_interrupt_base: u32,
    };

    pub fn getEntries(self: *const Madt) []const u8 {
        const base = @intFromPtr(self) + @sizeOf(Madt);
        const length = self.header.length - @sizeOf(Madt);
        return @as([*]const u8, @ptrFromInt(base))[0..length];
    }
};

pub const AcpiTables = struct {
    rdsp: *const RsdpDescriptor,
    madt: ?*const Madt,

    pub fn init(rsdp_addr: u64) !AcpiTables {
        const rsdp: *const RsdpDescriptor = @ptrFromInt(rsdp_addr);

        if (!rsdp.validate()) {
            return error.InvalidRsdp;
        }

        var tables = AcpiTables{
            .rsdp = rsdp,
            .madt = null,
        };

        if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
            try tables.parseXsdt();
        } else {
            try tables.parseRsdt();
        }

        return tables;
    }

    fn parseXsdt(self: *AcpiTables) !void {
        const xsdt: *const SdtHeader = @ptrFromInt(self.rsdp.xsdt_address);
        if (!xsdt.validate()) {
            return error.InvalidXsdt;
        }

        const entry_count = (xsdt.length - @sizeOf(SdtHeader)) / 8;
        const entries = @as([*]const u64, @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(SdtHeader)))[0..entry_count];

        for (entries) |entry_addr| {
            const header: *const SdtHeader = @ptrFromInt(entry_addr);
            if (std.mem.eql(u8, &header.signature, "APIC")) {
                self.madt = @ptrCast(header);
            }
        }
    }

    fn parseRsdt(self: *AcpiTables) !void {
        const rsdt: *const SdtHeader = @ptrFromInt(@as(u64, self.rsdp.rsdt_address));
        if (!rsdt.validate()) {
            return error.InvalidRsdt;
        }

        const entry_count = (rsdt.length - @sizeOf(SdtHeader)) / 4;
        const entries = @as([*]const u32, @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(SdtHeader)))[0..entry_count];

        for (entries) |entry_addr| {
            const header: *const SdtHeader = @ptrFromInt(@as(u64, entry_addr));
            if (std.mem.eql(u8, &header.signature, "APIC")) {
                self.madt = @ptrCast(header);
            }
        }
    }
};
