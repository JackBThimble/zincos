// ============================================================================
// Framebuffer Drawing
// ============================================================================

const std = @import("std");
const shared = @import("shared");
const BootInfo = shared.boot.BootInfo;

pub const Framebuffer = struct {
    base_address: ?*volatile u8 = null,
    width: u32,
    height: u32,
    pitch: u32,
    pixel_fmt: shared.boot.PixelFormat,

    pub fn init_framebuffer(base_address: u64, width: u32, height: u32, pitch: u32, pixel_fmt: shared.boot.PixelFormat) Framebuffer {
        return Framebuffer{
            .base_address = @ptrFromInt(base_address),
            .width = width,
            .height = height,
            .pitch = pitch,
            .pixel_fmt = pixel_fmt,
        };
    }

    pub fn put_pixel(self: *Framebuffer, x: u32, y: u32, r: u8, g: u8, b: u8) void {
        if (self.base_address == null) return;
        if (x >= self.width or y >= self.height) return;

        const offset: usize = @intCast(y * self.pitch + x * 4);
        const pixel: [*]volatile u8 = @ptrFromInt(@intFromPtr(self.base_address.?) + offset);

        if (self.pixel_fmt == shared.boot.PixelFormat.bgr) {
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

    pub fn fill_rect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8) void {
        var py: u32 = y;
        while (py < y + h and py < self.height) : (py += 1) {
            var px: u32 = x;
            while (px < x + w and px < self.width) : (px += 1) {
                self.put_pixel(px, py, r, g, b);
            }
        }
    }

    pub fn clear_screen(self: *Framebuffer, r: u8, g: u8, b: u8) void {
        self.fill_rect(0, 0, self.width, self.height, r, g, b);
    }

    // Simple 8x8 bitmap font for basic text
    const font_8x8 = @import("font.zig").Font8x8;

    pub fn draw_char(self: *Framebuffer, x: u32, y: u32, c: u8, r: u8, g: u8, b: u8) void {
        // const idx: usize = if (c >= 32 and c < 128) c - 32 else 0;
        const glyph = font_8x8.glyph(c);

        for (0..8) |row| {
            const bits = glyph[row];
            for (0..8) |col| {
                if ((bits >> @intCast(col)) & 1 == 1) {
                    self.put_pixel(x + @as(u32, @intCast(col)), y + @as(u32, @intCast(row)), r, g, b);
                }
            }
        }
    }

    pub fn draw_string(self: *Framebuffer, x: u32, y: u32, str: []const u8, r: u8, g: u8, b: u8) void {
        var cx = x;
        for (str) |c| {
            if (c == '\n') {
                // Handle newline - not implemented in this simple version
                continue;
            }
            self.draw_char(cx, y, c, r, g, b);
            cx += 8;
        }
    }
};
