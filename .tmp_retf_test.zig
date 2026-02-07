export fn foo() void {
    asm volatile (
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\rex64 lret
        \\1:
        ::: .{ .rax = true });
}
