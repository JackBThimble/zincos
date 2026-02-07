.text
.global gdt_reload_cs
.type gdt_reload_cs,@function
gdt_reload_cs:
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:  ret
