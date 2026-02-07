.code16
.section .ap_trampoline, "awx"
.global ap_trampoline_start
.global ap_trampoline_end
.global ap_trampoline_data

ap_trampoline_start:
    cli


    # Load GDT pointer
    lgdt (ap_trampoline_gdt_ptr - ap_trampoline_start + 0x8000)

    # Enable protected mode
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0

    ljmp $0x08, $(ap_trampoline_32 - ap_trampoline_start + 0x8000)

.code32
ap_trampoline_32:
    # Set up segments
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    # Enable PAE and OS support for SSE/XMM instructions
    mov %cr4, %eax
    or $0x620, %eax
    mov %eax, %cr4

    # Load page table (PML4)
    mov (ap_trampoline_pml4 - ap_trampoline_start + 0x8000), %eax
    mov %eax, %cr3

    # Enable long mode and NXE in EFER
    mov $0xc0000080, %ecx
    rdmsr
    or $0x900, %eax
    wrmsr

    # Enable paged protected mode with kernel expected CR0 bits
    mov %cr0, %eax
    and $0x9fffffff, %eax
    or $0x80010033, %eax
    mov %eax, %cr0

    # Far jump to 64-bit code
    ljmp $0x18, $(ap_trampoline_64 - ap_trampoline_start + 0x8000)

.code64
ap_trampoline_64:
    # Zero out segment registers
    mov $0x10, %rax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    # Load stack pointer
    mov (ap_trampoline_stack - ap_trampoline_start + 0x8000), %rsp

    # Load per-cpu pointer into GS_BASE
    mov (ap_trampoline_gs_base - ap_trampoline_start + 0x8000), %rdx
    mov %rdx, %rax
    shr $32, %rdx
    mov $0xc0000101, %ecx           # IA32_GS_BASE
    wrmsr

    # SysV arguments for apEntry(lapic_ptr, cpu_mgr_ptr, cpu_ptr)
    mov (ap_trampoline_lapic_ptr - ap_trampoline_start + 0x8000), %rdi
    mov (ap_trampoline_cpu_mgr_ptr - ap_trampoline_start + 0x8000), %rsi
    mov (ap_trampoline_cpu_ptr - ap_trampoline_start + 0x8000), %rdx

    # Load kernel entry point
    mov (ap_trampoline_entry - ap_trampoline_start + 0x8000), %rax

    # Mark as started
    movl $1, (ap_trampoline_started - ap_trampoline_start + 0x8000)
    mfence

    # Entering Zig C ABI function with expected stack state:
    # jumping (not calling), so synthesize an 8-byte return slot.
    pushq $0

    jmp *%rax

# 32-bit GDT for transition
.align 8
ap_trampoline_gdt_ptr:
    .word ap_trampoline_gdt_end - ap_trampoline_gdt - 1
    .long (ap_trampoline_gdt - ap_trampoline_start + 0x8000)

.align 8
ap_trampoline_gdt:
    .quad 0                         # Null descriptor
    .quad 0x00cf9a000000ffff        # 32-bit code
    .quad 0x00cf92000000ffff        # 32-bit data
    .quad 0x00af9a000000ffff        # 64-bit code
    .quad 0x00af92000000ffff        # 64-bit data
ap_trampoline_gdt_end:

# data area for ap startup
.align 8
ap_trampoline_data:
ap_trampoline_pml4:
    .quad 0
ap_trampoline_stack:
    .quad 0
ap_trampoline_gs_base:
    .quad 0
ap_trampoline_lapic_ptr:
    .quad 0
ap_trampoline_cpu_mgr_ptr:
    .quad 0
ap_trampoline_cpu_ptr:
    .quad 0
ap_trampoline_entry:
    .quad 0
ap_trampoline_started:
    .long 0

ap_trampoline_end:
