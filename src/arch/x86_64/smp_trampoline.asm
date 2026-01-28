; SMP AP Trampoline - Flat Binary
; Assembled with: nasm -f bin -o smp_trampoline.bin smp_trampoline.asm
; This code is copied to 0x7000 at runtime and executed by APs
; It transitions from 16-bit real mode -> 32-bit protected -> 64-bit long mode

ORG 0x7000

; Parameters live at 0x7800 (must match smp.zig)
%define PARAMS_PHYS 0x7800

; Offsets in TrampolineParams (must match smp.zig TrampolineParams)
%define OFF_CR3         0
%define OFF_GDT_LIMIT   8   ; u16
%define OFF_GDT_BASE    10  ; u64
%define OFF_ENTRY       24
%define OFF_STACK_TOP   32

; Temp GDT selectors
%define SEL_CODE32 0x08
%define SEL_DATA32 0x10
%define SEL_CODE64 0x18
%define SEL_DATA64 0x20

BITS 16
trampoline_start:
        cli
        cld

        ; Set up segments for real mode (DS=0 so we can access low memory)
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        ; Load temporary GDT
        lgdt [temp_gdtr]

        ; Enable protected mode
        mov eax, cr0
        or eax, 1
        mov cr0, eax

        ; Far jump to 32-bit protected mode
        jmp dword SEL_CODE32:pm32_entry

BITS 32
pm32_entry:
        ; Set up 32-bit data segments
        mov ax, SEL_DATA32
        mov ds, ax
        mov es, ax
        mov ss, ax

        ; Enable PAE (required for long mode)
        mov eax, cr4
        or eax, (1 << 5)
        mov cr4, eax

        ; Load CR3 from params
        mov eax, dword [PARAMS_PHYS + OFF_CR3]
        mov cr3, eax

        ; Enable long mode via EFER.LME
        mov ecx, 0xC0000080
        rdmsr
        or eax, (1 << 8)
        wrmsr

        ; Enable paging (activates long mode)
        mov eax, cr0
        or eax, (1 << 31)
        mov cr0, eax

        ; Far jump to 64-bit mode using temp GDT 64-bit code descriptor
        jmp dword SEL_CODE64:lm64_entry

BITS 64
DEFAULT ABS
lm64_entry:
        ; Load 64-bit data segments (temp GDT)
        mov ax, SEL_DATA64
        mov ds, ax
        mov es, ax
        mov ss, ax
        xor ax, ax
        mov fs, ax
        mov gs, ax

        ; Load stack from params
        mov rbx, [PARAMS_PHYS + OFF_STACK_TOP]
        mov rsp, rbx
        mov rbp, rbx

        ; Enable SSE (OSFXSR + OSXMMEXCPT) and clear EM
        mov rax, cr0
        and rax, ~(1 << 2)        ; clear EM
        or rax, (1 << 1) | (1 << 5) ; set MP, NE
        mov cr0, rax

        mov rax, cr4
        or rax, (1 << 9) | (1 << 10) ; OSFXSR | OSXMMEXCPT
        mov cr4, rax

        ; Load real GDT (64-bit base) from params and switch to its code segment
        lgdt [PARAMS_PHYS + OFF_GDT_LIMIT]
        push qword 0x08
        lea rax, [rel .after_real_gdt]
        push rax
        retfq

.after_real_gdt:
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax
        xor ax, ax
        mov fs, ax
        mov gs, ax

        ; Call entry(stack_top)
        mov rdi, rbx
        mov rax, [PARAMS_PHYS + OFF_ENTRY]
        call rax

        ; Should never return
.hang:
        hlt
        jmp .hang

; Align GDT data
align 8
temp_gdt:
        dq 0x0000000000000000   ; Null
        dq 0x00CF9A000000FFFF   ; 32-bit code (SEL_CODE32)
        dq 0x00CF92000000FFFF   ; 32-bit data (SEL_DATA32)
        dq 0x00AF9A000000FFFF   ; 64-bit code (SEL_CODE64)
        dq 0x00CF92000000FFFF   ; data (SEL_DATA64)
temp_gdt_end:

temp_gdtr:
        dw temp_gdt_end - temp_gdt - 1
        dd temp_gdt

trampoline_end:
