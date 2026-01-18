// UEFI console output utils

const std = @import("std");
const uefi = std.os.uefi;
const SimpleTextOutput = uefi.protocol.SimpleTextOutput;

var con_out: ?*SimpleTextOutput = null;

pub fn init(output: *SimpleTextOutput) void {
    con_out = output;
}

pub fn puts(msg: []const u8) void {
    for (msg) |c| {
        putchar(c);
    }
}

pub fn putchar(c: u8) void {
    if (con_out) |out| {
        const chars = [2:0]u16{ c, 0 };
        _ = out.outputString(&chars) catch unreachable;
    }
}

pub fn println(msg: []const u8) void {
    puts(msg);
    puts("\r\n");
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var msg: []u8 = undefined;

    msg = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    puts(msg);
}

pub fn printfln(comptime fmt: []const u8, args: anytype) void {
    printf(fmt, args);
    puts("\r\n");
}

pub fn clear() void {
    if (con_out) |out| {
        out.clearScreen() catch {};
    }
}
