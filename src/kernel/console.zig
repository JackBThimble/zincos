const std = @import("std");
const arch = @import("arch");
const Framebuffer = @import("framebuffer.zig").Framebuffer;

const CHAR_W = 8;
const CHAR_H = 8;
const LINE_SPACING = 2;
const ROW_H = CHAR_H + LINE_SPACING;

// =============================================================================
// State
// =============================================================================

const MAX_COLS = 256;
const MAX_ROWS = 128;

var fb: ?*Framebuffer = null;
var cols: u32 = 0;
var rows: u32 = 0;
var cursor_col: u32 = 0;
var cursor_row: u32 = 0;

var char_buf: [MAX_ROWS][MAX_COLS]u8 = [_][MAX_COLS]u8{[_]u8{' '} ** MAX_COLS} ** MAX_ROWS;
var color_buf: [MAX_ROWS][MAX_COLS]Color = [_][MAX_COLS]Color{[_]Color{.{ .r = 0xcc, .g = 0xcc, .b = 0xcc }} ** MAX_COLS} ** MAX_ROWS;

const Color = struct { r: u8, g: u8, b: u8 };
var fg_r: u8 = 0xcc;
var fg_g: u8 = 0xcc;
var fg_b: u8 = 0xcc;

const bg_r: u8 = 0x10;
const bg_g: u8 = 0x20;
const bg_b: u8 = 0x40;

const AnsiState = enum { normal, esc, bracket };
var ansi_state: AnsiState = .normal;
var ansi_param: u32 = 0;

var lock: SpinLock = .{};

const SerialAnsiState = enum { normal, esc, csi };
var serial_ansi_state: SerialAnsiState = .normal;
var serial_ansi_param: u32 = 0;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// =============================================================================
// Init
// =============================================================================

pub fn init(framebuf: *Framebuffer) void {
    fb = framebuf;
    cols = framebuf.width / CHAR_W;
    rows = framebuf.height / ROW_H;
    cursor_col = 0;
    cursor_row = 0;
    framebuf.clear_screen(bg_r, bg_g, bg_b);
}

// =============================================================================
// Combined writer - drop-in replacement for log.setWriter
// =============================================================================

pub fn combinedWrite(bytes: []const u8) void {
    lock.acquire();
    defer lock.release();
    writeLocked(bytes);
}

fn writeLocked(bytes: []const u8) void {
    writeSerialPlain(bytes);
    writeConsole(bytes);
}

// =============================================================================
// Console write (framebuffer only)
// =============================================================================

pub fn write(bytes: []const u8) void {
    lock.acquire();
    defer lock.release();
    writeConsole(bytes);
}

fn writeSerialPlain(bytes: []const u8) void {
    var out: [256]u8 = undefined;
    var n: usize = 0;
    for (bytes) |c| {
        switch (serial_ansi_state) {
            .normal => {
                if (c == 0x1b) {
                    serial_ansi_state = .esc;
                    serial_ansi_param = 0;
                } else {
                    out[n] = c;
                    n += 1;
                }
            },
            .esc => {
                if (c == '[') {
                    serial_ansi_state = .csi;
                    serial_ansi_param = 0;
                } else {
                    // drop unknown sequence
                    serial_ansi_state = .normal;
                }
            },
            .csi => {
                if (c >= '0' and c <= '9') {
                    serial_ansi_param = serial_ansi_param * 10 + (c - '0');
                } else if (c == ';' or c == '?') {
                    // continue parsing parameter list.
                } else if (c >= '@' and c <= '~') {
                    serial_ansi_state = .normal;
                    serial_ansi_param = 0;
                } else {
                    serial_ansi_state = .normal;
                    serial_ansi_param = 0;
                }
            },
        }

        if (n == out.len) {
            arch.serial.write(out[0..n]);
            n = 0;
        }
    }

    if (n != 0) arch.serial.write(out[0..n]);
}

fn writeConsole(bytes: []const u8) void {
    const f = fb orelse return;
    for (bytes) |c| {
        switch (ansi_state) {
            .normal => processChar(f, c),
            .esc => {
                if (c == '[') {
                    ansi_state = .bracket;
                    ansi_param = 0;
                } else {
                    ansi_state = .normal;
                }
            },
            .bracket => {
                if (c >= '0' and c <= '9') {
                    ansi_param = ansi_param * 10 + (c - '0');
                } else if (c == 'm') {
                    applyAnsiColor(ansi_param);
                    ansi_state = .normal;
                } else if (c == ';') {
                    // multi-param, just apply and reset
                    applyAnsiColor(ansi_param);
                    ansi_param = 0;
                } else {
                    ansi_state = .normal;
                }
            },
        }
    }
}

fn processChar(f: *Framebuffer, c: u8) void {
    switch (c) {
        '\n' => {
            cursor_col = 0;
            cursor_row += 1;
            scrollIfNeeded(f);
        },
        '\r' => {
            cursor_col = 0;
        },
        '\t' => {
            cursor_col = (cursor_col + 8) & ~@as(u32, 7);
            if (cursor_col >= cols) {
                cursor_col = 0;
                cursor_row += 1;
                scrollIfNeeded(f);
            }
        },
        0x08 => { // backspace
            if (cursor_col > 0) {
                cursor_col -= 1;
                char_buf[cursor_row][cursor_col] = ' ';
                // erase character cell
                const px = cursor_col * CHAR_W;
                const py = cursor_row * ROW_H;
                f.fill_rect(px, py, CHAR_W, ROW_H, bg_r, bg_g, bg_b);
            }
        },
        0x1b => {
            ansi_state = .esc;
        },
        0x20...0x7e => {
            if (cursor_col >= cols) {
                cursor_col = 0;
                cursor_row += 1;
                scrollIfNeeded(f);
            }
            const px = cursor_col * CHAR_W;
            const py = cursor_row * ROW_H;
            f.fill_rect(px, py, CHAR_W, ROW_H, bg_r, bg_g, bg_b);
            f.draw_char(px, py, c, fg_r, fg_g, fg_b);
            char_buf[cursor_row][cursor_col] = c;
            color_buf[cursor_row][cursor_col] = .{ .r = fg_r, .g = fg_g, .b = fg_b };
            cursor_col += 1;
        },
        else => {},
    }
}

// =============================================================================
// Scrolling
// =============================================================================

fn scrollIfNeeded(f: *Framebuffer) void {
    while (cursor_row >= rows) {
        scrollUp(f);
        cursor_row -= 1;
    }
}

fn scrollUp(f: *Framebuffer) void {
    for (0..rows - 1) |r| {
        char_buf[r] = char_buf[r + 1];
        color_buf[r] = color_buf[r + 1];
    }
    char_buf[rows - 1] = [_]u8{' '} ** MAX_COLS;
    color_buf[rows - 1] = [_]Color{.{ .r = fg_r, .g = fg_g, .b = fg_b }} ** MAX_COLS;
    redraw(f);
}

fn redraw(f: *Framebuffer) void {
    f.clear_screen(bg_r, bg_g, bg_b);
    for (0..rows) |r| {
        for (0..cols) |c| {
            const ch = char_buf[r][c];
            if (ch != ' ') {
                const clr = color_buf[r][c];
                f.draw_char(
                    @intCast(c * CHAR_W),
                    @intCast(r * ROW_H),
                    ch,
                    clr.r,
                    clr.g,
                    clr.b,
                );
            }
        }
    }
}

// =============================================================================
// ANSI color mapping
// =============================================================================

fn applyAnsiColor(param: u32) void {
    switch (param) {
        0 => {
            fg_r = 0xcc;
            fg_g = 0xcc;
            fg_b = 0xcc;
        },
        1 => {},
        31 => {
            fg_r = 0xff;
            fg_g = 0x55;
            fg_b = 0x55;
        },
        32 => {
            fg_r = 0x55;
            fg_g = 0xff;
            fg_b = 0x55;
        },
        33 => {
            fg_r = 0xff;
            fg_g = 0xff;
            fg_b = 0x55;
        },
        34 => {
            fg_r = 0x55;
            fg_g = 0x55;
            fg_b = 0xff;
        },
        36 => {
            fg_r = 0x55;
            fg_g = 0xff;
            fg_b = 0xff;
        },
        37 => {
            fg_r = 0xff;
            fg_g = 0xff;
            fg_b = 0xff;
        },
        else => {},
    }
}
