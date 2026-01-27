const serial = @import("../serial.zig");

// IDT Entry (16 bytes in long mode)
const IDTEntry = packed struct {
    offset_low: u16, // Offset bits 0-15
    selector: u16,
    ist: u8,
    flags: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const IDTR = packed struct {
    limit: u16,
    base: u64,
};

const IDTFlags = struct {
    const present: u8 = 1 << 7;
    const dpl_0: u8 = 0 << 5;
    const dpl_3: u8 = 3 << 5;
    const interrupt_gate: u8 = 0xe;
    const trap_gate: u8 = 0xf;
};

// Interrupt frame pushed by CPU
pub const InterruptFrame = packed struct {
    // Pushed by ISR stub
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,

    // Interrupt number and error code
    int_num: u64,
    error_code: u64,

    // Pushed by CPU automatically
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// 256 IDT entries
var idt: [256]IDTEntry align(16) = undefined;
var idtr: IDTR = undefined;

fn setIDTEntry(index: u8, handler: u64, selector: u16, ist: u8, flags: u8) void {
    idt[index] = IDTEntry{
        .offset_low = @truncate(handler & 0xffff),
        .selector = selector,
        .ist = ist,
        .flags = flags,
        .offset_mid = @truncate((handler >> 16) & 0xffff),
        .offset_high = @truncate((handler >> 32) & 0xffffffff),
        .reserved = 0,
    };
}

pub fn init() void {
    // Clear the IDT
    @memset(@as([*]u8, @ptrCast(&idt))[0..@sizeOf(@TypeOf(idt))], 0);

    // CPU Exceptions (0 - 31) - use IST for critical ones

    // (#DE) Divide Error
    setIDTEntry(
        0,
        @intFromPtr(&isr0),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#DB) Debug Exception (Breakpoints, Single-step)
    setIDTEntry(
        1,
        @intFromPtr(&isr1),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#NMI) Non-Maskable Interrupt
    setIDTEntry(
        2,
        @intFromPtr(&isr2),
        0x08,
        2, // IST2
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#BP) Breakpoint (INT3 instruction)
    setIDTEntry(
        3,
        @intFromPtr(&isr3),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_3 | IDTFlags.trap_gate,
    );
    // (#OF) Overflow (INTO instruction)
    setIDTEntry(
        4,
        @intFromPtr(&isr4),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#BR) BOUND Range Exceeded
    setIDTEntry(
        5,
        @intFromPtr(&isr5),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#UD) Invalid Opcode / Undefined Opcode
    setIDTEntry(
        6,
        @intFromPtr(&isr6),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#NM) Device Not Available (FPU related)
    setIDTEntry(
        7,
        @intFromPtr(&isr7),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#DF) Double Fault (Serious error, often system crash)
    setIDTEntry(
        8,
        @intFromPtr(&isr8),
        0x08,
        1, // IST1
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#) Deprecated (hardware keyboard interrupt)
    setIDTEntry(
        9,
        @intFromPtr(&isr9),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#TS) Invalid TSS (Task State Segment)
    setIDTEntry(
        10,
        @intFromPtr(&isr10),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#NP) Segment Not Present
    setIDTEntry(
        11,
        @intFromPtr(&isr11),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#SS) Stack-Segment Fault
    setIDTEntry(
        12,
        @intFromPtr(&isr12),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#GP) General Protection Fault
    setIDTEntry(
        13,
        @intFromPtr(&isr13),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#PF) Page Fault (Memory access issues)
    setIDTEntry(
        14,
        @intFromPtr(&isr14),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#) Deprecated
    setIDTEntry(
        15,
        @intFromPtr(&isr15),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#MF) x87 FPU Floating-Point Error
    setIDTEntry(
        16,
        @intFromPtr(&isr16),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#AC) Alignment Check
    setIDTEntry(
        17,
        @intFromPtr(&isr17),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#MC) Machine Check Exception (Hardware errors)
    setIDTEntry(
        18,
        @intFromPtr(&isr18),
        0x08,
        1, // IST1
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (#XM/#XF) SIMD Floating-Point Exception
    setIDTEntry(
        19,
        @intFromPtr(&isr19),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        20,
        @intFromPtr(&isr20),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        21,
        @intFromPtr(&isr21),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        22,
        @intFromPtr(&isr22),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        23,
        @intFromPtr(&isr23),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        24,
        @intFromPtr(&isr24),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        25,
        @intFromPtr(&isr25),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        26,
        @intFromPtr(&isr26),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        27,
        @intFromPtr(&isr27),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        28,
        @intFromPtr(&isr28),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        29,
        @intFromPtr(&isr29),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        30,
        @intFromPtr(&isr30),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );
    // (##) Reserved by Intel
    setIDTEntry(
        31,
        @intFromPtr(&isr31),
        0x08,
        0,
        IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
    );

    // IRQs (32-47) - hardware interrupts from PIC
    var i: u8 = 33;
    while (i < 48) : (i += 1) {
        setIDTEntry(
            i,
            @intFromPtr(irq_handlers[i - 32]),
            0x08,
            0,
            IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate,
        );
    }

    setIDTEntry(32, @intFromPtr(&irq0), 0x08, 0, IDTFlags.present | IDTFlags.dpl_0 | IDTFlags.interrupt_gate);

    // Set up IDTR
    idtr.limit = @sizeOf(@TypeOf(idt)) - 1;
    idtr.base = @intFromPtr(&idt);

    asm volatile (
        \\lidtq %[idtr]
        :
        : [idtr] "m" (idtr),
    );
}

const exception_messages = [32][]const u8{
    "[#DE] Divide By Zero",
    "[#DB] Debug",
    "[#NMI] Non-Maskable Interrupt",
    "[#BP] Breakpoint",
    "[#OF] Overflow",
    "[#BR] Bound Range Exceeded",
    "[#UD] Invalid Opcode",
    "[#NM] Device Not Available (No Math Coprocessor)",
    "[#DF] Double Fault",
    "[#n/a] Coprocessor Segment Overrun",
    "[#TS] Invalid TSS",
    "[#NP] Segment Not Present",
    "[#SS] Stack-Segment Fault",
    "[#GP] General Protection Fault",
    "[#PF] Page Fault",
    "[#n/a] Reserved",
    "[#MF] x87 Floating-Point Exception",
    "[#AC] Alignment Check",
    "[#MC] Machine Check",
    "[#XF] SIMD Floating-Point Exception",
    "[#VE] Virtualization Exception",
    "[#CP] Control Protection Exception",
    "[n/a] Reserved",
    "[n/a] Reserved",
    "[n/a] Reserved",
    "[n/a] Reserved",
    "[n/a] Reserved",
    "[n/a] Reserved",
    "[#HV] Hypervisor Injection Exception",
    "[#VC] VMM Communication Exception",
    "[#SX] Security Exception",
    "[n/a]Reserved",
};

// Common interrupt handler
export fn interruptHandler(frame: *InterruptFrame) callconv(.c) void {
    if (frame.int_num < 32) {
        serial.printfln("\n\nException: {s} ({d})", .{
            exception_messages[@intCast(frame.int_num)],
            frame.int_num,
        });

        serial.printfln("Error Code: 0x{x}", .{frame.error_code});

        serial.printfln("RIP: 0x{x}", .{frame.rip});

        serial.printfln("\nCS: 0x{x}", .{frame.cs});
        serial.printfln("RFLAGS: 0x{x}", .{frame.rflags});

        serial.printfln("\nRSP: 0x{x}", .{frame.rsp});
        serial.printfln("SS: 0x{x}", .{frame.ss});

        if (frame.int_num == 14) {
            @import("page_fault.zig").handlePageFault(frame.error_code, frame.rip, frame.cs, frame.rsp, frame.ss, frame.rflags);
        }

        while (true) {
            asm volatile ("hlt");
        }
    } else if (frame.int_num == 32) {
        @import("../lapic.zig").eoi();
        // TODO: Tickless scheduler hook later
        // For now: debug print occasionally
    } else if (frame.int_num > 32 and frame.int_num < 48) {
        handleIRQ(@truncate(frame.int_num - 32));
    }
}

// IRQ Handler
fn handleIRQ(irq: u8) void {
    switch (irq) {
        0 => {
            // Timer interrupt (PIT)
            // TODO: Timer handling
        },
        1 => {
            // Keyboard
            // TODO: Keyboard handling
        },
        else => {
            serial.printfln("Unhandled IRQ: {d}", .{irq});
        },
    }

    if (irq >= 8) {
        // If IRQ came from slave PIC, send EOI to both
        serial.outb(0xa0, 0x20);
    }
    serial.outb(0x20, 0x20);
}

// ISR stubs - implemented in assembly
extern fn isr0() callconv(.naked) void;
extern fn isr1() callconv(.naked) void;
extern fn isr2() callconv(.naked) void;
extern fn isr3() callconv(.naked) void;
extern fn isr4() callconv(.naked) void;
extern fn isr5() callconv(.naked) void;
extern fn isr6() callconv(.naked) void;
extern fn isr7() callconv(.naked) void;
extern fn isr8() callconv(.naked) void;
extern fn isr9() callconv(.naked) void;
extern fn isr10() callconv(.naked) void;
extern fn isr11() callconv(.naked) void;
extern fn isr12() callconv(.naked) void;
extern fn isr13() callconv(.naked) void;
extern fn isr14() callconv(.naked) void;
extern fn isr15() callconv(.naked) void;
extern fn isr16() callconv(.naked) void;
extern fn isr17() callconv(.naked) void;
extern fn isr18() callconv(.naked) void;
extern fn isr19() callconv(.naked) void;
extern fn isr20() callconv(.naked) void;
extern fn isr21() callconv(.naked) void;
extern fn isr22() callconv(.naked) void;
extern fn isr23() callconv(.naked) void;
extern fn isr24() callconv(.naked) void;
extern fn isr25() callconv(.naked) void;
extern fn isr26() callconv(.naked) void;
extern fn isr27() callconv(.naked) void;
extern fn isr28() callconv(.naked) void;
extern fn isr29() callconv(.naked) void;
extern fn isr30() callconv(.naked) void;
extern fn isr31() callconv(.naked) void;

const irq_handlers = [16]*const fn () callconv(.naked) void{
    irq0,  irq1,  irq2,  irq3,
    irq4,  irq5,  irq6,  irq7,
    irq8,  irq9,  irq10, irq11,
    irq12, irq13, irq14, irq15,
};

extern fn irq0() callconv(.naked) void;
extern fn irq1() callconv(.naked) void;
extern fn irq2() callconv(.naked) void;
extern fn irq3() callconv(.naked) void;
extern fn irq4() callconv(.naked) void;
extern fn irq5() callconv(.naked) void;
extern fn irq6() callconv(.naked) void;
extern fn irq7() callconv(.naked) void;
extern fn irq8() callconv(.naked) void;
extern fn irq9() callconv(.naked) void;
extern fn irq10() callconv(.naked) void;
extern fn irq11() callconv(.naked) void;
extern fn irq12() callconv(.naked) void;
extern fn irq13() callconv(.naked) void;
extern fn irq14() callconv(.naked) void;
extern fn irq15() callconv(.naked) void;
