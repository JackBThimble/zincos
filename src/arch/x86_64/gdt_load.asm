bits 64
default rel

global gdt_load_and_jump

gdt_load_and_jump:
    cli
    lgdt [rdi]

    ; Reload data segments
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    push qword 0x08
    lea rax, [rel .after]
    push rax

    db 0x48, 0xcb

.after:
    ret
