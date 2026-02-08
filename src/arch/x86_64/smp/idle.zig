pub fn run() noreturn {
    while (true) {
        asm volatile ("sti; hlt" ::: .{ .memory = true });
    }
}
