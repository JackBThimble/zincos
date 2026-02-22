const std = @import("std");
const lib = @import("lib");

const sc = lib.syscall;
const vfs = lib.vfs;
const IpcMessage = lib.ipc.Message;

const Handle = u64;
const LINE_MAX = 256;

pub export fn _start() callconv(.c) noreturn {
    run();
    while (true) {
        sc.sysSchedYield();
    }
}

fn run() void {
    lib.writeLit("\n===== ZincOS Shell ===\n\n");

    const vfs_ep = sc.sysVfsGetBootstrapEndpoint();
    const have_vfs = !sc.isSysErr(vfs_ep) and vfs_ep != 0;

    if (have_vfs) {
        lib.writeLit("VFS available.\n");
    } else {
        lib.writeLit("VFS not available. File commands disabled.\n");
    }

    var line_buf: [LINE_MAX]u8 = undefined;

    while (true) {
        lib.writeLit("zincos> ");
        const len = readLine(&line_buf);
        if (len == 0) continue;

        const line = line_buf[0..len];
        dispatch(line, if (have_vfs) vfs_ep else null);
    }
}

// =============================================================================
// Line editing
// =============================================================================

fn readLine(buf: []u8) usize {
    var pos: usize = 0;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = sc.sysRead(0, &ch, 1);
        if (n == 0) continue;

        switch (ch[0]) {
            '\n' => {
                lib.writeLit("\n");
                return pos;
            },
            8, 127 => { // backspace or DEL
                if (pos > 0) {
                    pos -= 1;
                    lib.writeLit("\x08 \x08");
                }
            },
            else => {
                if (ch[0] >= 0x20 and pos < buf.len - 1) {
                    buf[pos] = ch[0];
                    pos += 1;
                    sc.sysWrite(1, &ch, 1);
                }
            },
        }
    }
}

// =============================================================================
// Command dispatch
// =============================================================================

fn dispatch(line: []const u8, vfs_ep: ?Handle) void {
    const trimmed = lib.trimWhitespace(line);
    if (trimmed.len == 0) return;

    const cmd = lib.firstToken(trimmed);
    const args = lib.trimWhitespace(trimmed[cmd.len..]);

    if (lib.strEql(cmd, "help")) {
        cmdHelp();
    } else if (lib.strEql(cmd, "echo")) {
        cmdEcho(args);
    } else if (lib.strEql(cmd, "pid")) {
        cmdPid();
    } else if (lib.strEql(cmd, "cpuid")) {
        cmdCpuId();
    } else if (lib.strEql(cmd, "yield")) {
        cmdYield();
    } else if (lib.strEql(cmd, "clear")) {
        cmdClear();
    } else if (lib.strEql(cmd, "ls")) {
        cmdLs(vfs_ep);
    } else if (lib.strEql(cmd, "cat")) {
        cmdCat(vfs_ep, args);
    } else {
        lib.writeLit("unknown command: ");
        sc.sysWrite(1, cmd.ptr, cmd.len);
        lib.writeLit("\ntype 'help' for available commands\n");
    }
}

// =============================================================================
// Built-in commands
// =============================================================================

fn cmdHelp() void {
    lib.writeLit(
        \\  help            show this message
        \\  echo <text>     print text
        \\  pid             show process id
        \\  cpuid           show current cpu id
        \\  yield           yield the cpu
        \\  clear           clear screen
        \\  ls              list files in vfs
        \\  cat <file>      print file contents
        \\
    );
}

fn cmdEcho(args: []const u8) void {
    if (args.len > 0) {
        sc.sysWrite(1, args.ptr, args.len);
    }
    lib.writeLit("\n");
}

fn cmdPid() void {
    const pid = sc.sysGetPid();
    lib.writeFmt("pid={}\n", .{pid});
}

fn cmdCpuId() void {
    const cpu = sc.sysGetCpuId();
    lib.writeFmt("cpu={}\n", .{cpu});
}

fn cmdYield() void {
    lib.writeLit("yielding...\n");
    sc.sysSchedYield();
    lib.writeLit("returned from yield\n");
}

fn cmdClear() void {
    lib.writeLit("\x1b[2J\x1b[H");
}

// =============================================================================
// VFS commands
// =============================================================================

fn cmdLs(vfs_ep: ?Handle) void {
    const ep = vfs_ep orelse {
        lib.writeLit("vfs not available\n");
        return;
    };

    // Open root directory by name "." or ""
    const opened = lib.openFile(ep, ".") orelse {
        // TODO: Try listing known files by stat-ing common names
        lib.writeLit("could not open root directory\n");
        return;
    };

    const stat = lib.statFile(ep, opened.fd) orelse {
        _ = lib.closeFile(ep, opened.fd);
        lib.writeLit("could not stat root\n");
        return;
    };

    lib.writeFmt("files: size = {} flags=0x{x}\n", .{ stat.file_size, stat.flags });

    var offset: u64 = 0;
    while (true) {
        const rd = lib.readChunk(ep, opened.fd, offset, 256) orelse break;
        if (rd.bytes_read == 0) break;
        const data = rd.inline_data[0..@intCast(rd.bytes_read)];
        sc.sysWrite(1, data.ptr, data.len);
        offset += rd.bytes_read;
    }

    _ = lib.closeFile(ep, opened.fd);
}

fn cmdCat(vfs_ep: ?Handle, args: []const u8) void {
    const ep = vfs_ep orelse {
        lib.writeLit("vfs not available\n");
        return;
    };

    const filename = lib.firstToken(args);
    if (filename.len == 0) {
        lib.writeLit("usage: cat <filename>\n");
        return;
    }

    const opened = lib.openFile(ep, filename) orelse {
        lib.writeLit("could not open: ");
        sc.sysWrite(1, filename.ptr, filename.len);
        lib.writeLit("\n");
        return;
    };

    lib.writeFmt("size={}\n", .{opened.file_size});

    var offset: u64 = 0;
    while (true) {
        const rd = lib.readChunk(ep, opened.fd, offset, 256) orelse break;
        if (rd.bytes_read == 0) break;
        const data = rd.inline_data[0..@intCast(rd.bytes_read)];
        sc.sysWrite(1, data.ptr, data.len);
        offset += rd.bytes_read;
    }

    lib.writeLit("\n");
    _ = lib.closeFile(ep, opened.fd);
}
