// ============================================================================
// Framebuffer Drawing
// ============================================================================

const std = @import("std");
const common = @import("common");
const BootInfo = common.BootInfo;

pub var g_framebuffer: common.FramebufferInfo = undefined;

pub fn init_framebuffer(info: *const BootInfo) void {
    g_framebuffer = info.framebuffer;
    g_framebuffer.base_address = info.framebuffer.base_address + info.hhdm_base;
}

pub fn put_pixel(x: u32, y: u32, r: u8, g: u8, b: u8) void {
    if (g_framebuffer.base_address == 0) return;
    if (x >= g_framebuffer.width or y >= g_framebuffer.height) return;

    const offset: usize = @intCast(y * g_framebuffer.pitch + x * 4);
    const pixel: [*]volatile u8 = @ptrFromInt(g_framebuffer.base_address + offset);

    if (g_framebuffer.pixel_format == common.PixelFormat.bgr) {
        pixel[0] = b;
        pixel[1] = g;
        pixel[2] = r;
        pixel[3] = 0xFF;
    } else {
        pixel[0] = r;
        pixel[1] = g;
        pixel[2] = b;
        pixel[3] = 0xFF;
    }
}

pub fn fill_rect(x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
    var py: u32 = y;
    while (py < y + h and py < g_framebuffer.height) : (py += 1) {
        var px: u32 = x;
        while (px < x + w and px < g_framebuffer.width) : (px += 1) {
            put_pixel(px, py, r, g, b);
        }
    }
}

pub fn clear_screen(r: u8, g: u8, b: u8) void {
    fill_rect(0, 0, g_framebuffer.width, g_framebuffer.height, r, g, b);
}

// Simple 8x8 bitmap font for basic text
const font_8x8 = @import("font.zig").Font8x8;

pub fn draw_char(x: u32, y: u32, c: u8, r: u8, g: u8, b: u8) void {
    // const idx: usize = if (c >= 32 and c < 128) c - 32 else 0;
    const glyph = font_8x8.glyph(c);

    for (0..8) |row| {
        const bits = glyph[row];
        for (0..8) |col| {
            if ((bits >> @intCast(col)) & 1 == 1) {
                put_pixel(x + @as(u32, @intCast(col)), y + @as(u32, @intCast(row)), r, g, b);
            }
        }
    }
}

pub fn draw_string(x: u32, y: u32, str: []const u8, r: u8, g: u8, b: u8) void {
    var cx = x;
    for (str) |c| {
        if (c == '\n') {
            // Handle newline - not implemented in this simple version
            continue;
        }
        draw_char(cx, y, c, r, g, b);
        cx += 8;
    }
}
