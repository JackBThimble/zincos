# ==============================================================================
# x86_64 User Mode Entry Trampoline
# ==============================================================================
# 
# enter_user_mode(user_rip: u64, user_rsp: u64, arg0: u64, arg1: u64, arg2: u64)
#   %rdi = user RIP (entry_point)
#   %rsi = user RSP (top of user stack)
#   %rdx = startup arg0
#   %rcx = startup arg1
#   %r8  = startup arg2
#
# Builds an iretq frame and drops to ring 3.
#
# GDT selectors (must match PerCpu.Gdt):
#   0x08 = kernel code  (ring 0)
#   0x10 = kernel data  (ring 0)
#   0x18 = user data    (ring 3) -> selector = 0x18 | 3 = 0x1b
#   0x20 = user code    (ring 3) -> selector = 0x20 | 3 = 0x23
#
# Before iretq, swapgs so that:
#   - GS_BASE becomes user's GS (was in KERNEL_GS_BASE, set to 0 by caller)
#   - KERNEL_GS_BASE becomes per-CPU pointer (was in GS_BASE)
# This way, the next interrupt from user mode will swapgs and get the per-CPU 
# pointer back into GS_BASE.
#
# iretq frame (pushed in reverse order):
#   SS      = 0x1b                  (user data | RPL 3)
#   RSP     = user stack pointer
#   RFLAGS  = 0x202                 (IF=1, reserved bit 1 set)
#   CS      = 0x23                  (user code | RPL 3)
#   RIP     = user entry point
# ==============================================================================

.set USER_CS, 0x23      # GDT index 4 (user code) | RPL 3
.set USER_SS, 0x1b      # GDT index 3 (user data) | RPL 3
.set RFLAGS_IF, 0x202   # IF=1, bit1=1 (reserved, always set)

.text
.global enter_user_mode
.type enter_user_mode, @function
.align 16

enter_user_mode:
    # Preserve entry context and startup arguments.
    movq %rdi, %rax
    movq %rsi, %rbx
    movq %rdx, %r12
    movq %rcx, %r13
    movq %r8, %r14

    # Build iretq frame
    pushq $USER_SS          # SS
    pushq %rbx              # RSP (user stack)
    pushq $RFLAGS_IF        # RFLAGS
    pushq $USER_CS          # CS
    pushq %rax              # RIP (user entry)

    # Place startup arguments in user ABI registers.
    movq %r12, %rdi
    movq %r13, %rsi
    movq %r14, %rdx

    # Zero remaining registers to avoid leaking kernel state.
    xorq %rax, %rax
    xorq %rbx, %rbx
    xorq %rcx, %rcx
    xorq %rbp, %rbp
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15

    # Swap GS: kernel GS_BASE -> KERNEL_GS_BASE (for next interrupt)
    #          user GS (from KERNEL_GS_BASE) -> GS_BASE
    swapgs

    iretq
