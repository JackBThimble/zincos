const std = @import("std");
const builtin = @import("builtin");

pub const Serial = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/serial.zig"),
    .aarch64 => @import("aarch64/serial.zig"),
    else => @compileError("Unsupported architecture"),
};

pub fn init() void {
    Serial.init();
}

pub fn putChar(c: u8) void {
    Serial.putChar(c);
}

pub fn print(buf: []const u8) void {
    Serial.print(buf);
}

pub fn println(buf: []const u8) void {
    Serial.println(buf);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    Serial.printf(fmt, args);
}

pub fn printfln(comptime fmt: []const u8, args: anytype) void {
    Serial.printfln(fmt, args);
}

pub fn write(bytes: []const u8) void {
    Serial.write(bytes);
}
