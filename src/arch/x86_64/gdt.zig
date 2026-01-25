// GDT Entry structure (8 bytes)
const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

// 64-bit TSS Descriptor (16 bytes - takes 2 GDT slots)
const TSSDescriptor = packed struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,
};

// Task State Segment for x86_64
const TSS = packed struct {
    reserved0: u32,
    rsp0: u64, // Stack pointer for ring 0
    rsp1: u64, // unused
    rsp2: u64, // unused
    reserved1: u64,
    ist1: u64, // Interrupt Stack Table 1
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved2: u64,
    reserved3: u16,
    iomap_base: u16,
};

const GDTR = packed struct {
    limit: u16,
    base: u64,
};

const Access = struct {
    const present: u8 = 1 << 7;
    const ring_0: u8 = 0 << 5;
    const ring_3: u8 = 3 << 5;
    const code_data: u8 = 1 << 4;
    const executable: u8 = 1 << 3;
    const direction: u8 = 1 << 2;
    const readable: u8 = 1 << 1;
    const writable: u8 = 1 << 1;
    const accessed: u8 = 1 << 0;

    const tss_available: u8 = 0x09; // available 64-bit tss
};

const Flags = struct {
    const granularity_4k: u8 = 1 << 7; // 4K page granularity
    const size_32: u8 = 1 << 6; // 32-bit protected mode
    const long_mode: u8 = 1 << 5; // 64-bit long mode
};

// GDT with 6 entries + TSS descriptor (takes 2 slots, 7 total)
// Layout: null, kernel code, kernel data, user code, user data, TSS (16 bytes)
var gdt: [7]u64 align(16) = undefined;
var gdtr: GDTR = undefined;
var tss: TSS align(16) = undefined;

// Stack for ring 0 (kernel stack for syscalls)
var kernel_stack: [4096 * 4]u8 align(16) = undefined;

// IST stacks (for critical interrupts like double faults)
var double_fault_stack: [4096 * 4]u8 align(16) = undefined;
var nmi_stack: [4096 * 4]u8 align(16) = undefined;

fn createGDTEntry(base: u32, limit: u32, access: u8, flags: u8) u64 {
    var entry: u64 = 0;
    entry |= @as(u64, limit & 0xffff);
    entry |= @as(u64, base & 0xffff) << 16;
    entry |= @as(u64, (base >> 16) & 0xff) << 32;
    entry |= @as(u64, access) << 40;
    entry |= @as(u64, (limit >> 16) & 0x0f) << 48;
    entry |= @as(u64, flags & 0xf0) << 48;
    entry |= @as(u64, (base >> 24) & 0xff) << 56;

    return entry;
}

fn createTSSDescriptor(tss_ptr: *TSS) void {
    const base = @intFromPtr(tss_ptr);
    const limit = @sizeOf(TSS) - 1;

    // Lower 64 bits (index 5)
    var lower: u64 = 0;
    lower |=
        @as(u64, limit & 0xffff); // limit low
    lower |=
        @as(u64, base & 0xffff) << 16; // base low
    lower |=
        @as(u64, (base >> 16) & 0xff) << 32; // base middle
    lower |=
        @as(u64, Access.present | Access.tss_available) << 40;
    lower |=
        @as(u64, (limit >> 16) & 0x0f) << 48; // limit high
    lower |=
        @as(u64, (base >> 24) & 0xff) << 56; // base high

    const upper: u64 = (base >> 32) & 0xffffffff;

    gdt[5] = lower;
    gdt[6] = upper;
}

pub fn init() void {
    // Null descriptor
    gdt[0] = 0;

    // Kernel code segment (0x08)
    gdt[1] = createGDTEntry(
        0,
        0xfffff,
        Access.present | Access.ring_0 | Access.code_data | Access.executable | Access.readable,
        Flags.granularity_4k | Flags.long_mode,
    );

    // Kernel data segment (0x10)
    gdt[2] = createGDTEntry(
        0,
        0xfffff,
        Access.present | Access.ring_0 | Access.code_data | Access.writable,
        Flags.granularity_4k | Flags.size_32,
    );

    // User code segment (0x18)
    gdt[3] = createGDTEntry(
        0,
        0xfffff,
        Access.present | Access.ring_3 | Access.code_data | Access.executable | Access.readable,
        Flags.granularity_4k | Flags.long_mode,
    );

    // User data segment (0x20)
    gdt[4] = createGDTEntry(
        0,
        0xfffff,
        Access.present | Access.ring_3 | Access.code_data | Access.writable,
        Flags.granularity_4k | Flags.size_32,
    );

    // Initialize TSS
    @memset(@as([*]u8, @ptrCast(&tss))[0..@sizeOf(TSS)], 0);

    // Set ring 0 stack pointer (top of stack, grows downward)
    tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len;

    // Set up IST entries for critical interrupts
    // IST1 for double faults
    tss.ist1 = @intFromPtr(&double_fault_stack) + double_fault_stack.len;

    // IST2 for NMI
    tss.ist2 = @intFromPtr(&nmi_stack) + nmi_stack.len;

    // I/O map base (no I/O bitmap, set to size of TSS)
    tss.iomap_base = @sizeOf(TSS);

    // Create TSS descriptor (takes slots 5 and 6)
    createTSSDescriptor(&tss);

    gdtr.limit = @sizeOf(@TypeOf(gdt)) - 1;
    gdtr.base = @intFromPtr(&gdt);

    lgdt();
    ltss();
}

extern fn gdt_load_and_jump(gdtr_ptr: *const GDTR) callconv(.{ .x86_64_sysv = .{} }) void;

fn lgdt() void {
    gdt_load_and_jump(&gdtr);
}

fn ltss() void {
    asm volatile (
        \\mov $0x28, %%ax
        \\ltr %%ax
        ::: .{ .rax = true, .memory = true });
}

// Helper function to update RSP0 (call this when switching tasks/processes)
pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}
