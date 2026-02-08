# ==============================================================================
# X86_64 Context Switch
# ==============================================================================
#
# context_switch_asm(old_sp_ptr: *u64, new_sp: u64)
#   %rdi = pointer to old task's saved SP
#   %rsi = new task's saved SP
#
# Register layout on stack
#   [return address]        <- pushed by `call`
#   [rflags]
#   [r15]
#   [r14]
#   [r13]
#   [r12]
#   [rbx]
#   [rbp]                   <- saved SP points here
# ==============================================================================

.text

.global context_switch_asm
.type context_switch_asm, @function
context_switch_asm:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushfq

    movq %rsp, (%rdi)
    movq %rsi, %rsp

    popfq
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

# ==============================================================================
# load_context_asm(new_sp: u64)
#   %rdi = new SP -- first schedule on a CPU, no old state to save
#
# ==============================================================================

.global load_context_asm
.type load_context_asm, @function
load_context_asm:
    movq %rdi, %rsp

    popfq
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

