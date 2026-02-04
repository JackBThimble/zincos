const std = @import("std");
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const GraphicsOutput = uefi.protocol.GraphicsOutput;

const console = @import("console.zig");
const boot_info = @import("shared").boot;

pub const SetupError = error{
    NoGraphicsOutput,
    ProtocolError,
};

pub fn setup(boot_services: *BootServices) SetupError!boot_info.FramebufferInfo {
    console.println("[*] Setting up graphics output...");

    const gop = boot_services.locateProtocol(
        GraphicsOutput,
        null,
    ) catch {
        console.println("[!] Failed to locate GOP");
        return SetupError.NoGraphicsOutput;
    } orelse {
        console.println("[!] GOP not found");
        return SetupError.NoGraphicsOutput;
    };

    const mode_info = gop.mode.info;

    console.printfln("[*] Current mode: {d}x{d}", .{ mode_info.horizontal_resolution, mode_info.vertical_resolution });

    var best_mode: u32 = gop.mode.mode;
    var best_width: u32 = mode_info.horizontal_resolution;
    var best_height: u32 = mode_info.vertical_resolution;

    var mode_num: u32 = 0;
    while (mode_num < gop.mode.max_mode) : (mode_num += 1) {
        if (gop.queryMode(mode_num)) |info| {
            const w = info.horizontal_resolution;
            const h = info.vertical_resolution;
            if ((w == 1920 and (h == 1080 or h == 1200)) or (w == 1280 and h == 720 and best_width < 1920)) {
                best_mode = mode_num;
                best_width = w;
                best_height = h;
            }
        } else |_| {}
    }

    if (best_mode != gop.mode.mode) {
        console.printfln("[*] Switching to mode {d}x{d}...", .{ best_width, best_height });
        gop.setMode(best_mode) catch {
            console.println("[!] Failed to set mode, using default");
        };
    }

    const final_info = gop.mode.info;
    const fb_info = boot_info.FramebufferInfo{
        .base_address = gop.mode.frame_buffer_base,
        .width = final_info.horizontal_resolution,
        .height = final_info.vertical_resolution,
        .pitch = final_info.pixels_per_scan_line * 4,
        .bpp = 32,
        .pixel_format = switch (final_info.pixel_format) {
            .red_green_blue_reserved_8_bit_per_color => .rgb,
            .blue_green_red_reserved_8_bit_per_color => .bgr,
            .bit_mask => .bitmask,
            .blt_only => .blt_only,
        },
        ._reserved = 0,
    };

    console.printfln("[+] Framebuffer at 0x{x}, {d}x{d}", .{
        fb_info.base_address,
        fb_info.width,
        fb_info.height,
    });

    return fb_info;
}
