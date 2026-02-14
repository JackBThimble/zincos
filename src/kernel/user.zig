const std = @import("std");
const sched = @import("sched/mod.zig");
const mm = @import("mm");

const USER_DEMO_CODE_VA: u64 = 0x0000_0080_0040_0000;
const USER_DEMO_STACK_PAGES: usize = 4;
const USER_DEMO_STACK_TOP: u64 = 0x0000_0080_7000_0000;
const USER_DEMO_LOAD_CODE_FLAGS = mm.vmm.MapFlags{
    .user = true,
    .executable = true,
    .writable = true,
};

const user_demo_code = [_]u8{
    0xb8, 0x02, 0x00, 0x00, 0x00, // mov eax, 2 ; shared.syscall.Number.sched_yield
    0x0f, 0x05, // syscall
    0xeb, 0xf7, // jmp back to mov eax, 2
};

pub fn spawnDemoUserProcess(allocator: std.mem.Allocator) !void {
    const as = try mm.address_space.AddressSpace.create(allocator);
    errdefer as.destroy(allocator);

    try as.mapAnonymous(USER_DEMO_CODE_VA, 1, USER_DEMO_LOAD_CODE_FLAGS);

    const stack_base = USER_DEMO_STACK_TOP - USER_DEMO_STACK_PAGES * mm.PAGE_SIZE;
    try as.mapAnonymous(stack_base, USER_DEMO_STACK_PAGES, mm.vmm.MapFlags.user_stack);

    as.activate();

    defer mm.address_space.activateKernel();

    const user_text: [*]u8 = @ptrFromInt(@as(usize, @intCast(USER_DEMO_CODE_VA)));
    @memcpy(user_text[0..user_demo_code.len], user_demo_code[0..]);

    _ = try sched.core.spawnUser(
        as,
        USER_DEMO_CODE_VA,
        USER_DEMO_STACK_TOP,
        20,
        "user-demo",
    );
}
