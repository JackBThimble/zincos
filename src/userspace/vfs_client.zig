const std = @import("std");
const shared = @import("shared");

const sc = shared.syscall;
const vfs = shared.vfs_protocol;
const IpcMessage = shared.ipc_message.Message;

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(shared.ipc_message.MAX_DATA_WORDS);

pub export fn _start() callconv(.c) noreturn {
    run();
    while (true) {
        sysSchedYield();
    }
}

fn run() void {
    writeLit("vfs_client: starting\n");

    const ep = sysVfsGetBootstrapEndpoint();
    if (isSysErr(ep) or ep == 0) {
        writeFmt("vfs_client: no bootstrap endpoint (ret=0x{x})\n", .{ep});
        return;
    }

    const pid = sysGetPid();
    writeFmt("vfs_client: pid={} endpoint={}\n", .{ pid, ep });

    const opened = openFile(ep, "ramfs_server") orelse return;
    writeFmt("vfs_client: open ok fd={} size={}\n", .{ opened.fd, opened.file_size });

    const stat = statFile(ep, opened.fd) orelse {
        _ = closeFile(ep, opened.fd);
        return;
    };
    writeFmt("vfs_client: stat size={} flags=0x{x}\n", .{ stat.file_size, stat.flags });

    var offset: u64 = 0;
    var total: u64 = 0;
    var dumped = false;

    while (true) {
        const read = readChunk(ep, opened.fd, offset, 256) orelse break;
        if (read.bytes_read == 0) break;

        if (!dumped) {
            dumpInlineHex(read.inline_data[0..@intCast(read.bytes_read)]);
            dumped = true;
        }

        offset += read.bytes_read;
        total += read.bytes_read;
    }

    writeFmt("vfs_client: read total={}\n", .{total});

    if (!closeFile(ep, opened.fd)) return;
    writeLit("vfs_client: close ok\n");
}

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
    if (isSysErr(rc)) {
        writeFmt("vfs_client: ipc_call(open) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        const resp = vfs.deserialize(vfs.OpenResponse, payloadOfConst(&reply));
        if (resp.err != .none) {
            writeFmt("vfs_client: open err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return .{ .fd = resp.fd, .file_size = resp.file_size };
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.OpenResponse, payloadOfConst(&reply));
        writeFmt("vfs_client: open err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    writeFmt("vfs_client: open unexpected label=0x{x}\n", .{reply.label()});
    return null;
}

fn statFile(endpoint: Handle, fd: u32) ?vfs.StatResponse {
    const req = vfs.StatRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.stat), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.StatRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) {
        writeFmt("vfs_client: ipc_call(stat) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.stat_data)) {
        const resp = vfs.deserialize(vfs.StatResponse, payloadOfConst(&reply));
        if (resp.err != .none) {
            writeFmt("vfs_client: stat err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return resp.*;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.StatResponse, payloadOfConst(&reply));
        writeFmt("vfs_client: stat err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    writeFmt("vfs_client: stat unexpected label=0x{x}\n", .{reply.label()});
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
    if (isSysErr(rc)) {
        writeFmt("vfs_client: ipc_call(read) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.read_inline)) {
        const resp = vfs.deserialize(vfs.ReadResponse, payloadOfConst(&reply));
        if (resp.err != .none) {
            writeFmt("vfs_client: read err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return resp.*;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.ReadResponse, payloadOfConst(&reply));
        writeFmt("vfs_client: read err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    writeFmt("vfs_client: read unexpected label=0x{x}\n", .{reply.label()});
    return null;
}

fn closeFile(endpoint: Handle, fd: u32) bool {
    const req = vfs.CloseRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.close), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.CloseRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sysIpcCall(endpoint, &msg, &reply);
    if (isSysErr(rc)) {
        writeFmt("vfs_client: ipc_call(close) failed ret=0x{x}\n", .{rc});
        return false;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        return true;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.OpenResponse, payloadOfConst(&reply));
        writeFmt("vfs_client: close err={}\n", .{@intFromEnum(err.err)});
        return false;
    }

    writeFmt("vfs_client: close unexpected label=0x{x}\n", .{reply.label()});
    return false;
}

fn dumpInlineHex(bytes: []const u8) void {
    const n = @min(bytes.len, 16);
    var line: [128]u8 = undefined;
    var pos: usize = 0;

    const prefix = "vfs_client: first bytes";
    @memcpy(line[0..prefix.len], prefix);
    pos = prefix.len;

    for (bytes[0..n]) |b| {
        if (pos + 3 >= line.len) break;
        line[pos] = ' ';
        pos += 1;
        const hi = "0123456789abcdef"[(b >> 4) & 0xf];
        const lo = "0123456789abcdef"[b & 0xf];
        line[pos] = hi;
        line[pos + 1] = lo;
        pos += 2;
    }

    line[pos] = '\n';
    pos += 1;
    sysWrite(line[0..pos]);
}

fn payloadOf(msg: *IpcMessage) *[vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

fn payloadOfConst(msg: *const IpcMessage) *const [vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

fn writeLit(comptime s: []const u8) void {
    sysWrite(s);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sysWrite(out);
}

fn isSysErr(ret: u64) bool {
    return @as(i64, @bitCast(ret)) < 0;
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

fn sysWrite(bytes: []const u8) void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sys_write)),
          [fd] "{rdi}" (@as(u64, 1)),
          [buf] "{rsi}" (@as(u64, @intCast(@intFromPtr(bytes.ptr)))),
          [len] "{rdx}" (@as(u64, @intCast(bytes.len))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysSchedYield() void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sched_yield)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
