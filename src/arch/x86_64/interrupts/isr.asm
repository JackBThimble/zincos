; isr.asm - Interrupt Service Routine stubs
bits 64

global isr0, isr1, isr2, isr3, isr4, isr5, isr6, isr7, isr8, isr9
global isr10, isr11, isr12, isr13, isr14, isr15, isr16, isr17, isr18, isr19
global isr20, isr21, isr22, isr23, isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31

global irq0, irq1, irq2, irq3, irq4, irq5, irq6, irq7
global irq8, irq9, irq10, irq11, irq12, irq13, irq14, irq15

extern interruptHandler

; Macro for ISRs without error code
%macro ISR_NOERR 1
isr%1:
    push qword 0                ; Push dummy error code
    push qword %1               ; Push interrupt number 
    jmp isr_common
%endmacro

; Macro for ISRs with error code (CPU pushes automatically)
%macro ISR_ERR 1
isr%1:
    push qword %1               ; Push interrupt number
    jmp isr_common
%endmacro

; Macro for IRQs
%macro IRQ 2
irq%1:
    push qword 0                ; Dummy error code
    push qword %2               ; IRQ number (32 + %1)
    jmp isr_common
%endmacro

; CPU Exception
ISR_NOERR 0     ; divide by zero
ISR_NOERR 1     ; debug
ISR_NOERR 2     ; NMI
ISR_NOERR 3     ; Breakpoint
ISR_NOERR 4     ; Overflow
ISR_NOERR 5     ; Bound range exceeded
ISR_NOERR 6     ; Invalid Opcode
ISR_NOERR 7     ; Device not available
ISR_ERR 8       ; Double Fault (has error code)
ISR_NOERR 9     ; Coprocessor Segment Overrun (deprecated)
ISR_ERR 10      ; Invalid TSS (has error code)
ISR_ERR 11      ; Segment not present (has error code)
ISR_ERR 12      ; Stack-Segment Fault (has error code)
ISR_ERR 13      ; General Protection Fault (has error code)
ISR_ERR 14      ; Page Fualt (has error code)
ISR_NOERR 15    ; Reserved
ISR_NOERR 16    ; x87 FPU error
ISR_ERR 17      ; Alignment Check (has error code)
ISR_NOERR 18    ; Machine Check
ISR_NOERR 19    ; SIMD FPU Exception
ISR_NOERR 20    ; Virtualization Exception
ISR_ERR 21      ; Control Protection Exception (has error code)
ISR_NOERR 22    ; Reserved
ISR_NOERR 23    ; Reserved
ISR_NOERR 24    ; Reserved
ISR_NOERR 25    ; Reserved
ISR_NOERR 26    ; Reserved
ISR_NOERR 27    ; Reserved
ISR_NOERR 28    ; Hypervisor Injection Exception
ISR_ERR 29      ; VMM Communication Exception (has error code)
ISR_ERR 30      ; Security Excpetion (has error code)
ISR_NOERR 31    ; Reserved

; IRQ Handlers (remapped to 32-47)
IRQ 0, 32       ; PIT Timer
IRQ 1, 33       ; Keyboard
IRQ 2, 34       ; Cascade (never raised)
IRQ 3, 35       ; COM2
IRQ 4, 36       ; COM1
IRQ 5, 37       ; LPT2
IRQ 6, 38       ; Floppy
IRQ 7, 39       ; LPT1 (spurious)
IRQ 8, 40       ; RTC
IRQ 9, 41       ; Free
IRQ 10, 42      ; Free
IRQ 11, 43      ; Free
IRQ 12, 44      ; PS/2 Mouse
IRQ 13, 45      ; FPU
IRQ 14, 46      ; Primary ATA
IRQ 15, 47      ; Secondary ATA

; Common ISR Handler
isr_common: 
    ; save all registers
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Call Zig interrupt handler
    mov rdi, rsp                    ; Pass pointer to interrupt frame
    call interruptHandler

    ; Restore all registers
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ; Clean up interrupt number and error code
    add rsp, 16

    ; Return from interrupt
    iretq
