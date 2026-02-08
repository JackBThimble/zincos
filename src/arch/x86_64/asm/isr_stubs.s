# ==============================================================================
# x86_64 ISR Stub Table
# ==============================================================================

.text

.extern interrupt_dispatch
.extern sched_check_preempt

.altmacro

.macro ISR_NOERR vec
    .align 16
    isr_stub_\vec:
        pushq $0
        pushq $\vec
        jmp isr_common
.endm

.macro ISR_ERR vec
    .align 16
    isr_stub_\vec:
        pushq $\vec
        jmp isr_common
.endm

.macro ISR_TABLE_ENTRY vec
    .quad isr_stub_\vec
.endm

isr_common:
    cli
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %r12
    movq %r12, %rdi
    andq $-16, %rsp
    call interrupt_dispatch
    call sched_check_preempt
    movq %r12, %rsp


    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp
    iretq

# CPU exceptions 0-31
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR 8
ISR_NOERR 9
ISR_ERR 10
ISR_ERR 11
ISR_ERR 12
ISR_ERR 13
ISR_ERR 14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR 17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR 29
ISR_ERR 30
ISR_NOERR 31

# Device interrupts 32-255
.set i, 32
.rept 224
    ISR_NOERR %i
    .set i, i + 1
.endr

# Stub pointer table
.section .rodata
.align 8
.global isr_stub_table
isr_stub_table:
.set i, 0
.rept 256
    ISR_TABLE_ENTRY %i
    .set i, i + 1
.endr
