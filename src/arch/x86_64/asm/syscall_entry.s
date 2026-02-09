# ==============================================================================
# x86_64 SYSCALL Entry / Exit Stub
# ==============================================================================
#
# Entered via SYSCALL from ring 3. Hardware saves:
#   RCX <- user RIP
#   R11 <- user RFLAGS
#   RFLAGS &= ~FMASK
# 
# Convention:
#   RAX = syscall number
#   RDI, RSI, RDX, R10, R8, R9 = arguments
#   Return: RAX = result
# 
# Per-CPU offsets (must match PerCpu extern struct):
#   GS:8 = user_rsp         scratch for user RSP
#   GS:16 = kernel_stack    kernel RSP to load
#
# ==============================================================================

.set PERCPU_USER_RSP, 8
.set PERCPU_KERNEL_STACK, 16

.text
.global syscall_entry_stub
.type syscall_entry_stub, @function
.align 16

syscall_entry_stub:
    swapgs
    movq %rsp, %gs:PERCPU_USER_RSP
    movq %gs:PERCPU_KERNEL_STACK, %rsp

    # Build SyscallFrame (16 pushes = 128 bytes)
    pushq %gs:PERCPU_USER_RSP               # user_rsp
    pushq %r11                              # user RFLAGS
    pushq %rcx                              # user RIP
    pushq %rax                              # syscall number
    pushq %rdi                              # arg0
    pushq %rsi                              # arg1
    pushq %rdx                              # arg2
    pushq %r10                              # arg3
    pushq %r8                               # arg4
    pushq %r9                               # arg5
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # Save frame base in callee-saved register
    movq %rsp, %r12

    # Stack is already 16-byte aligned here
    movq %r12, %rdi
    call syscall_dispatch

    # Restore frame base
    movq %r12, %rsp

    # Write return value into frame's RAX slot
    movq %rax, 96(%rsp)

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r9
    popq %r8
    popq %r10
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax                               # return value
    popq %rcx                               # user RIP
    popq %r11                               # user RFLAGS
    popq %rsp                               # user RSP

    swapgs
    sysretq
