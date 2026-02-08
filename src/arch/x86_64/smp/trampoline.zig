pub const TRAMPOLINE_ADDR = 0x8000;

extern const ap_trampoline_start: u8;
extern const ap_trampoline_data: u8;

pub const Stage = struct {
    pub const real_mode: u32 = 0x10;
    pub const protected_mode: u32 = 0x20;
    pub const long_mode: u32 = 0x30;
    pub const jumped_to_entry: u32 = 0x40;
    pub const gs_base_set: u32 = 0x50;
    pub const gdt_loaded: u32 = 0x60;
    pub const lapic_enabled: u32 = 0x70;
    pub const marked_online: u32 = 0x80;
    pub const idle: u32 = 0x90;
};

pub const Error = struct {
    pub const none: u32 = 0;
    pub const bad_args: u32 = 0xe001;
    pub const startup_timeout: u32 = 0xe100;
};

pub const Mailbox = extern struct {
    pml4: u64,
    stack: u64,
    gs_base: u64,
    lapic_ptr: u64,
    cpu_mgr_ptr: u64,
    cpu_ptr: u64,
    entry: u64,
    stage: u32,
    err: u32,
    started: u32,
};

pub fn mailbox() *volatile Mailbox {
    const off = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    return @ptrFromInt(TRAMPOLINE_ADDR + off);
}

pub fn setup() !void {
    if (@offsetOf(Mailbox, "stage") != 56) @compileError("Mailox.stage offset mismatch");
    if (@offsetOf(Mailbox, "started") != 64) @compileError("Mailbox.started offset mismatch");
    const size = @intFromPtr(&ap_trampoline_data) - @intFromPtr(&ap_trampoline_start);
    const src = @as([*]const u8, @ptrCast(&ap_trampoline_start))[0..size];
    const dst = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR));
    @memcpy(dst[0..size], src);
}
