const std = @import("std");

extern fn gdt_reload_cs() callconv(.c) void;
/// Per-CPU data structure - first field MUST be cpu_id for GS:0 access
pub const PerCpu = extern struct {
    /// CPU ID read via %gs:0. GS base points to this field.
    cpu_id: u32 = 0,

    /// APIC ID from MADT (GS:4)
    apic_id: u32 = 0,

    /// Syscall scratch for user RSP (GS:8)
    user_rsp: u64 = 0,

    /// Kernel stack pointer (top of stack) (GS:16)
    kernel_stack: u64 = 0,

    /// Current task/thread pointer (GS:24)
    current_task: u64 = 0,

    /// Am I Bootstrap Processor??? (GS:32) - 0=AP, 1=BSP
    is_bsp: u8 = 0,
    _pad0: [3]u8 = .{ 0, 0, 0 },
    /// CPU online flag (GS:36) - atomic: 0=offline, 1=online
    online: u32 = 0,
    /// GS:40
    scratch0: u64 = 0,
    /// GS:48
    scratch1: u64 = 0,
    /// CPU-local allocator count GS:56
    alloc_count: u64 = 0,
    /// CPU-local free count GS:64
    free_count: u64 = 0,
    /// TSS for this CPU GS:72
    tss: Tss = std.mem.zeroes(Tss),
    /// GDT for this CPU GS:72 + @sizeOf(Tss)
    gdt: Gdt = Gdt.init(),

    comptime {
        if (@offsetOf(PerCpu, "cpu_id") != 0) @compileError("cpu_id must be at GS:0");
        if (@offsetOf(PerCpu, "apic_id") != 4) @compileError("apic_id must be at GS:4");
        if (@offsetOf(PerCpu, "user_rsp") != 8) @compileError("user_rsp must be at GS:* - update syscall_entry.s");
        if (@offsetOf(PerCpu, "kernel_stack") != 16) @compileError("kernel_stack must be at GS:16 - update syscall_entry.s");
        if (@offsetOf(PerCpu, "current_task") != 24) @compileError("current task must be at GS:24");
    }

    pub fn isBsp(self: *const PerCpu) bool {
        return self.is_bsp != 0;
    }

    pub fn setBsp(self: *PerCpu, val: bool) void {
        self.is_bsp = if (val) 1 else 0;
    }

    pub fn isOnline(self: *const PerCpu) bool {
        return @atomicLoad(u32, &self.online, .acquire) != 0;
    }

    pub fn setOnline(self: *PerCpu, val: bool) void {
        @atomicStore(u32, &self.online, if (val) 1 else 0, .release);
    }

    pub fn getCurrentTask(self: *const PerCpu) ?*anyopaque {
        const addr = @atomicLoad(u64, &self.current_task, .acquire);
        return if (addr == 0) null else @ptrFromInt(addr);
    }

    pub fn setCurrentTask(self: *PerCpu, ptr: ?*anyopaque) void {
        const addr: u64 = if (ptr) |p| @intFromPtr(p) else 0;
        @atomicStore(u64, &self.current_task, addr, .release);
    }

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

    pub const Gdt = extern struct {
        entries: [8]u64 = [_]u64{0} ** 8,

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
            const limit: u16 = @intCast(@sizeOf(@TypeOf(self.entries)) - 1);
            const base: u64 = @intFromPtr(&self.entries);

            if (!isCanonical(base)) @panic("GDT base non-canonical");
            if ((base & 0x7) != 0) @panic("GDT base not 8-byte aligned");

            var gdtr: [10]u8 = undefined;
            gdtr[0] = @truncate(limit);
            gdtr[1] = @truncate(limit >> 8);
            inline for (0..8) |i| {
                gdtr[2 + i] = @truncate(base >> @intCast(i * 8));
            }

            asm volatile ("lgdtq (%[ptr])"
                :
                : [ptr] "r" (&gdtr[0]),
                : .{ .memory = true });

            gdt_reload_cs();
        }

        pub fn loadTss(_: *const Gdt) void {
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
    return @ptrFromInt(getGsBase());
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

fn isCanonical(va: u64) bool {
    const top = va >> 48;
    return top == 0 or top == 0xffff;
}
