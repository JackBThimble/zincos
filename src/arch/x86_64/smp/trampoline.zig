pub const TRAMPOLINE_ADDR = 0x8000;

extern const ap_trampoline_start: u8;
extern const ap_trampoline_data: u8;

pub const Mailbox = extern struct {
    pml4: u64,
    stack: u64,
    gs_base: u64,
    lapic_ptr: u64,
    cpu_mgr_ptr: u64,
    cpu_ptr: u64,
    entry: u64,
    started: u32,
};

pub fn mailbox() *volatile Mailbox {
    const off = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    return @ptrFromInt(TRAMPOLINE_ADDR + off);
}

pub fn setup() !void {
    const size = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    const src = @as([*]const u8, @ptrCast(&ap_trampoline_start))[0..size];
    const dst = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR));
    @memcpy(dst[0..size], src);
}
