const std = @import("std");
const shared = @import("shared");

const sc = shared.syscall;
const vfs = shared.vfs_protocol;
const IpcMessage = shared.ipc_message.Message;

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(shared.ipc_message.MAX_DATA_WORDS);

const LINE_MAX = 256;

pub export fn _start() callconv(.c) noreturn {
    run();
    while (true) {
        sysSchedYield();
    }
}

fn run() void {
    writeLit("\n===== ZincOS Shell ===\n\n");

    const vfs_ep = sysVfsGetBootstrapEndpoint();
    const have_vfs = !isSysErr(vfs_ep) and vfs_ep != 0;

    if (have_vfs) {
        writeLit("VFS available.\n");
    } else {
        writeLit("VFS not available. File commands disabled.\n");
    }

    var line_buf: [LINE_MAX]u8 = undefined;

    while (true) {
        writeLit("zincos> ");
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
        const n = sysRead(0, &ch, 1);
        if (n == 0) continue;

        switch (ch[0]) {
            '\n' => {
                writeLit("\n");
                return pos;
            },
            8, 127 => { // backspace or DEL
                if (pos > 0) {
                    pos -= 1;
                    writeLit("\x08 \x08");
                }
            },
            else => {
                if (ch[0] >= 0x20 and pos < buf.len - 1) {
                    buf[pos] = ch[0];
                    pos += 1;
                    sysWrite(1, &ch, 1);
                }
            },
        }
    }
}

// =============================================================================
// Command dispatch
// =============================================================================

fn dispatch(line: []const u8, vfs_ep: ?Handle) void {
    const trimmed = trimWhitespace(line);
    if (trimmed.len == 0) return;

    const cmd = firstToken(trimmed);
    const args = trimWhitespace(trimmed[cmd.len..]);

    if (strEql(cmd, "help")) {
        cmdHelp();
    } else if (strEql(cmd, "echo")) {
        cmdEcho(args);
    } else if (strEql(cmd, "pid")) {
        cmdPid();
    } else if (strEql(cmd, "cpuid")) {
        cmdCpuId();
    } else if (strEql(cmd, "yield")) {
        cmdYield();
    } else if (strEql(cmd, "clear")) {
        cmdClear();
    } else if (strEql(cmd, "ls")) {
        cmdLs(vfs_ep);
    } else if (strEql(cmd, "cat")) {
        cmdCat(vfs_ep, args);
    } else {
        writeLit("unknown command: ");
        sysWrite(1, cmd.ptr, cmd.len);
        writeLit("\ntype 'help' for available commands\n");
    }
}

// =============================================================================
// Built-in commands
// =============================================================================

fn cmdHelp() void {
    writeLit(
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
        sysWrite(1, args.ptr, args.len);
    }
    writeLit("\n");
}

fn cmdPid() void {
    const pid = sysGetPid();
    writeFmt("pid={}\n", .{pid});
}

fn cmdCpuId() void {
    const cpu = sysGetCpuId();
    writeFmt("cpu={}\n", .{cpu});
}

fn cmdYield() void {
    writeLit("yielding...\n");
    sysSchedYield();
    writeLit("returned from yield\n");
}

fn cmdClear() void {
    writeLit("\x1b[2J\x1b[H");
}

// =============================================================================
// VFS commands
// =============================================================================

fn cmdLs(vfs_ep: ?Handle) void {
    const ep = vfs_ep orelse {
        writeLit("vfs not available\n");
        return;
    };

    // Open root directory by name "." or ""
    const opened = openFile(ep, ".") orelse {
        // TODO: Try listing known files by stat-ing common names
        writeLit("could not open root directory\n");
        return;
    };

    const stat = statFile(ep, opened.fd) orelse {
        _ = closeFile(ep, opened.fd);
        writeLit("could not stat root\n");
        return;
    };

    writeFmt("files: size = {} flags=0x{x}\n", .{ stat.file_size, stat.flags });

    var offset: u64 = 0;
    while (true) {
        const rd = readChunk(ep, opened.fd, offset, 256) orelse break;
        if (rd.bytes_read == 0) break;
        const data = rd.inline_data[0..@intCast(rd.bytes_read)];
        sysWrite(1, data.ptr, data.len);
        offset += rd.bytes_read;
    }

    _ = closeFile(ep, opened.fd);
}

fn cmdCat(vfs_ep: ?Handle, args: []const u8) void {
    const ep = vfs_ep orelse {
        writeLit("vfs not available\n");
        return;
    };

    const filename = firstToken(args);
    if (filename.len == 0) {
        writeLit("usage: cat <filename>\n");
        return;
    }

    const opened = openFile(ep, filename) orelse {
        writeLit("could not open: ");
        sysWrite(1, filename.ptr, filename.len);
        writeLit("\n");
        return;
    };

    writeFmt("size={}\n", .{opened.file_size});

    var offset: u64 = 0;
    while (true) {
        const rd = readChunk(ep, opened.fd, offset, 256) orelse break;
        if (rd.bytes_read == 0) break;
        const data = rd.inline_data[0..@intCast(rd.bytes_read)];
        sysWrite(1, data.ptr, data.len);
        offset += rd.bytes_read;
    }

    writeLit("\n");
    _ = closeFile(ep, opened.fd);
}

// =============================================================================
// VFS helpers
// =============================================================================

fn openFile(endpoint: Handle, name: []const u8) ?struct { fd: u32, file_size: u64 } {
    var req = std.mem.zeroes(vfs.OpenRequest);
    const name_len = @min(name.len, req.name.len - 1);
    @memcpy(req.name[0..name_len], name[0..name_len]);
    req.name[name_len] = 0;
    req.flags = .{ .read = true };

    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.open), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.OpenRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        const resp = vfs.deserialize(vfs.OpenResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return .{ .fd = resp.fd, .file_size = resp.file_size };
    }
    return null;
}

fn readChunk(endpoint: Handle, fd: u32, offset: u64, len: u64) ?vfs.ReadResponse {
    const req = vfs.ReadRequest{
        .fd = fd,
        .offset = offset,
        .length = len,
    };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.read), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.ReadRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.read_inline)) {
        const resp = vfs.deserialize(vfs.ReadResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return resp.*;
    }
    return null;
}

fn statFile(endpoint: Handle, fd: u32) ?vfs.StatResponse {
    const req = vfs.StatRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.stat), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.StatRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.stat_data)) {
        const resp = vfs.deserialize(vfs.StatResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return resp.*;
    }
    return null;
}

fn closeFile(endpoint: Handle, fd: u32) bool {
    const req = vfs.CloseRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.close), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.CloseRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) return false;
    return reply.label() == @intFromEnum(vfs.VfsOp.ok);
}

// =============================================================================
// String utilities
// =============================================================================
fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') start += 1;
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') end -= 1;
    return s[start..end];
}

fn firstToken(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != ' ') end += 1;
    return s[0..end];
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

// =============================================================================
// IPC / payload helpers
// =============================================================================

fn payloadOf(msg: *IpcMessage) *[vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

fn payloadOfConst(msg: *const IpcMessage) *const [vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

// =============================================================================
// Formatting
// =============================================================================
fn writeLit(comptime s: []const u8) void {
    sysWrite(1, s.ptr, s.len);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sysWrite(1, out.ptr, out.len);
}

fn sysRead(fd: u64, buf: [*]u8, len: usize) usize {
    const ret = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_read)),
          [fd_] "{rdi}" (fd),
          [buf_] "{rsi}" (@as(u64, @intFromPtr(buf))),
          [len] "{rdx}" (@as(u64, @intCast(len))),
        : .{ .rcx = true, .r11 = true, .memory = true });

    if (isSysErr(ret)) return 0;
    return @intCast(ret);
}

fn sysWrite(fd: u64, buf: [*]const u8, len: usize) void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_write)),
          [fd_] "{rdi}" (fd),
          [buf_] "{rsi}" (@as(u64, @intFromPtr(buf))),
          [len_] "{rdx}" (@as(u64, @intCast(len))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcCall(endpoint: Handle, req: *const IpcMessage, reply: *IpcMessage) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_call)),
          [ep] "{rdi}" (endpoint),
          [req] "{rsi}" (@as(u64, @intCast(@intFromPtr(req)))),
          [reply] "{rdx}" (@as(u64, @intCast(@intFromPtr(reply)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysSchedYield() void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sched_yield)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysVfsGetBootstrapEndpoint() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.vfs_get_bootstrap_endpoint)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysGetPid() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.get_pid)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysGetCpuId() u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.get_cpu_id)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn isSysErr(ret: u64) bool {
    return @as(i64, @bitCast(ret)) < 0;
}
