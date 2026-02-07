const std = @import("std");

extern fn gdt_reload_cs() callconv(.c) void;
/// Per-CPU data structure - first field MUST be cpu_id for GS:0 access
pub const PerCpu = struct {
    /// CPU ID read via %gs:0. GS base points to this field.
    cpu_id: u32,

    /// APIC ID from MADT
    apic_id: u32,

    /// Am I Bootstrap Processor???
    is_bsp: bool,

    /// CPU online flag
    online: std.atomic.Value(bool),

    /// Kernel stack pointer (top of stack)
    kernel_stack: u64,

    /// Current task/thread pointer
    current_task: ?*anyopaque,

    /// TSS for this CPU
    tss: Tss,

    /// GDT for this CPU
    gdt: Gdt,

    /// Scratch space for syscalls/interrupts
    scratch0: u64,
    scratch1: u64,

    /// CPU-local allocator statistics
    alloc_count: usize,
    free_count: usize,

    pub const Tss = extern struct {
        reserved0: u32 = 0,
        rsp0: u64 = 0, // Kernel stack for ring 0
        rsp1: u64 = 0, // Kernel stack for ring 1
        rsp2: u64 = 0, // Kernel stack for ring 2
        reserved1: u64 = 0,
        ist1: u64 = 0, // Interrupt stacks
        ist2: u64 = 0,
        ist3: u64 = 0,
        ist4: u64 = 0,
        ist5: u64 = 0,
        ist6: u64 = 0,
        ist7: u64 = 0,
        reserved2: u64 = 0,
        reserved3: u16 = 0,
        iomap_base: u16 = @sizeOf(Tss),
    };

    pub const Gdt = struct {
        entries: [8]u64,

        pub const Entry = enum(usize) {
            null_segment = 0, // First segment MUST be null
            kernel_code = 1,
            kernel_data = 2,
            user_code = 3,
            user_data = 4,
            tss_low = 5,
            tss_high = 6,
        };

        pub fn init() Gdt {
            return .{
                .entries = [_]u64{
                    0x0000_0000_0000_0000, // NULL
                    0x00af_9a00_0000_ffff, // Kernel code (64-bit)
                    0x00af_9200_0000_ffff, // Kernel data
                    0x00af_fa00_0000_ffff, // User code (64-bit)
                    0x00af_f200_0000_ffff, // User data
                    0, // TSS low (filled later)
                    0, // TSS high (filled later)
                    0, // Reserved
                },
            };
        }

        pub fn setTss(self: *Gdt, tss: *const Tss) void {
            const tss_addr = @intFromPtr(tss);
            const tss_size = @sizeOf(Tss);

            // TSS Descriptor is 16 bytes (2 entries)
            var low: u64 = 0;
            var high: u64 = 0;

            // Low part
            low |= (tss_size - 1) & 0xffff;
            low |= (tss_addr & 0xff_ffff) << 16;
            low |= 0x89 << 40;
            low |= ((tss_size - 1) & 0xf_0000) << 32;
            low |= ((tss_addr >> 24) & 0xff) << 56;

            // High part
            high = tss_addr >> 32;

            self.entries[@intFromEnum(Entry.tss_low)] = low;
            self.entries[@intFromEnum(Entry.tss_high)] = high;
        }

        pub fn load(self: *const Gdt) void {
            const gdtr = packed struct {
                limit: u16,
                base: u64,
            }{
                .limit = @sizeOf(@TypeOf(self.entries)) - 1,
                .base = @intFromPtr(&self.entries),
            };

            asm volatile ("lgdtq %[gdtr]"
                :
                : [gdtr] "m" (gdtr),
            );

            // TODO: us inline assembly IF zig fixes the lretq downgrading to
            // lretl issue
            gdt_reload_cs();
        }

        pub fn loadTss(self: *const Gdt) void {
            _ = self;
            const tss_selector: u16 = @intFromEnum(Entry.tss_low) * 8;
            asm volatile ("ltrw %[sel]"
                :
                : [sel] "r" (tss_selector),
            );
        }
    };
};

/// Get current CPU ID from GS:0
pub inline fn getCpuId() u32 {
    return asm volatile ("movl %%gs:0, %[id]"
        : [id] "=r" (-> u32),
    );
}

/// Get pointer to current CPU's per-CPU data
pub inline fn getPerCpu() *PerCpu {
    const gs_base: usize = @intCast(getGsBase());
    return @ptrFromInt(gs_base - @offsetOf(PerCpu, "cpu_id"));
}

/// Set GS_BASE MSR to point to per-CPU data
pub fn setGsBase(percpu: *PerCpu) void {
    // Point GS base at cpu_id itself so %gs:0 is always cpu_id.
    const addr = @intFromPtr(&percpu.cpu_id);
    const low: u32 = @truncate(addr);
    const high: u32 = @truncate(addr >> 32);

    // IA32_GS_BASE
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (@as(u32, 0xc000_0101)),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Get GS_BASE MSR
pub fn getGsBase() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (@as(u32, 0xc000_0101)),
    );

    return (@as(u64, high) << 32) | low;
}
