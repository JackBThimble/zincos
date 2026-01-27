BITS 16
DEFAULT REL

global smp_trampoline_start
global smp_trampoline_end

; Parameters live at 0x7800 ( must match smp.zig )
%define PARAMS_PHYS 0x7800

; Offsets in TrampolineParams
%define OFF_CR3         0
%define OFF_GDT_PTR     8
%define OFF_ENTRY       16
%define OFF_STACK_TOP   24

smp_trampoline_start:
        cli
        cld

        ; --- Enter protected mode quickly (minimal) ---
        ; Load a temporary 16-bit GDT (flat) to enter PM,
        ; then we'll load the real 64-bit GDT from params.
        lgdt [temp_gdtr]

        mov eax, cr0
        or eax, 1
        mov cr0, eax

        jmp 0x08:pm32_entry

BITS 32
pm32_entry:
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax

        ; Enable PAE
        mov eax, cr4
        or eax, (1 << 5)
        mov cr4, eax

        ; Load CR3 from params
        mov eax, dword [PARAMS_PHYS + OFF_CR3]
        mov edx, dword [PARAMS_PHYS + OFF_CR3 + 4]
        ; write CR3 (only low 32 used in many setups, but keep correctness)
        mov cr3, eax

        ; Enable LME (EFER.LME)
        mov ecx, 0xC0000080      ; IA32_EFER
        rdmsr
        or eax, (1 << 8)         ; LME
        wrmsr

        ; Enable paging (CR0.PG)
        mov eax, cr0
        or eax, (1 << 31)
        mov cr0, eax

        ; Load 64-bit GDT from params
        lgdt [PARAMS_PHYS + OFF_GDT_PTR]

        ; Far jump to 64-bit code segment (assumes selector 0x08 is 64-bit code)
        jmp 0x08:lm64_entry

BITS 64
lm64_entry:
        ; Load data segments (assumes selector 0x10 is data)
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax

        ; Set stack from params
        mov rax, [PARAMS_PHYS + OFF_STACK_TOP]
        mov rsp, rax
        mov rbp, rax

        ; Call entry(stack_top)
        mov rdi, rax
        mov rax, [PARAMS_PHYS + OFF_ENTRY]
        call rax

.hang:
        hlt
        jmp .hang

; --- Temporary GDT to enter protected mode ---
align 8
temp_gdt:
        dq 0x0000000000000000
        dq 0x00CF9A000000FFFF  ; code
        dq 0x00CF92000000FFFF  ; data

temp_gdtr:
        dw temp_gdt_end - temp_gdt - 1
        dd temp_gdt

temp_gdt_end:

smp_trampoline_end:

