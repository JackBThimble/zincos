pub fn run() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
