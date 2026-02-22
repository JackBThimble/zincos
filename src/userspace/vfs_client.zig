const std = @import("std");
const lib = @import("lib");

const sc = lib.syscall;
const vfs = lib.vfs;
const ipc = lib.ipc;
const IpcMessage = lib.ipc.Message;

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(ipc.MAX_DATA_WORDS);

pub export fn _start() callconv(.c) noreturn {
    run();
    while (true) {
        sc.sysSchedYield();
    }
}

fn run() void {
    lib.writeLit("vfs_client: starting\n");

    const ep = sc.sysVfsGetBootstrapEndpoint();
    if (sc.isSysErr(ep) or ep == 0) {
        lib.writeFmt("vfs_client: no bootstrap endpoint (ret=0x{x})\n", .{ep});
        return;
    }

    const pid = sc.sysGetPid();
    lib.writeFmt("vfs_client: pid={} endpoint={}\n", .{ pid, ep });

    const opened = openFile(ep, "ramfs_server") orelse return;
    lib.writeFmt("vfs_client: open ok fd={} size={}\n", .{ opened.fd, opened.file_size });

    const stat = statFile(ep, opened.fd) orelse {
        _ = closeFile(ep, opened.fd);
        return;
    };
    lib.writeFmt("vfs_client: stat size={} flags=0x{x}\n", .{ stat.file_size, stat.flags });

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

    lib.writeFmt("vfs_client: read total={}\n", .{total});

    if (!closeFile(ep, opened.fd)) return;
    lib.writeLit("vfs_client: close ok\n");
}

fn openFile(endpoint: Handle, name: []const u8) ?struct { fd: u32, file_size: u64 } {
    var req = std.mem.zeroes(vfs.OpenRequest);
    const name_len = @min(name.len, req.name.len - 1);
    @memcpy(req.name[0..name_len], name[0..name_len]);
    req.name[name_len] = 0;
    req.flags = .{ .read = true };

    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.open), PAYLOAD_WORDS);
    lib.payloadOf(&msg).* = vfs.serialize(vfs.OpenRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sc.sysIpcCall(endpoint, &msg, &reply);
    if (sc.isSysErr(rc)) {
        lib.writeFmt("vfs_client: ipc_call(open) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        const resp = vfs.deserialize(vfs.OpenResponse, lib.payloadOfConst(&reply));
        if (resp.err != .none) {
            lib.writeFmt("vfs_client: open err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return .{ .fd = resp.fd, .file_size = resp.file_size };
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.OpenResponse, lib.payloadOfConst(&reply));
        lib.writeFmt("vfs_client: open err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    lib.writeFmt("vfs_client: open unexpected label=0x{x}\n", .{reply.label()});
    return null;
}

fn statFile(endpoint: Handle, fd: u32) ?vfs.StatResponse {
    const req = vfs.StatRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.stat), PAYLOAD_WORDS);
    lib.payloadOf(&msg).* = vfs.serialize(vfs.StatRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sc.sysIpcCall(endpoint, &msg, &reply);
    if (sc.isSysErr(rc)) {
        lib.writeFmt("vfs_client: ipc_call(stat) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.stat_data)) {
        const resp = vfs.deserialize(vfs.StatResponse, lib.payloadOfConst(&reply));
        if (resp.err != .none) {
            lib.writeFmt("vfs_client: stat err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return resp.*;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.StatResponse, lib.payloadOfConst(&reply));
        lib.writeFmt("vfs_client: stat err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    lib.writeFmt("vfs_client: stat unexpected label=0x{x}\n", .{reply.label()});
    return null;
}

fn readChunk(endpoint: Handle, fd: u32, offset: u64, len: u64) ?vfs.ReadResponse {
    const req = vfs.ReadRequest{
        .fd = fd,
        .offset = offset,
        .length = len,
    };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.read), PAYLOAD_WORDS);
    lib.payloadOf(&msg).* = vfs.serialize(vfs.ReadRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sc.sysIpcCall(endpoint, &msg, &reply);
    if (sc.isSysErr(rc)) {
        lib.writeFmt("vfs_client: ipc_call(read) failed ret=0x{x}\n", .{rc});
        return null;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.read_inline)) {
        const resp = vfs.deserialize(vfs.ReadResponse, lib.payloadOfConst(&reply));
        if (resp.err != .none) {
            lib.writeFmt("vfs_client: read err={}\n", .{@intFromEnum(resp.err)});
            return null;
        }
        return resp.*;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.ReadResponse, lib.payloadOfConst(&reply));
        lib.writeFmt("vfs_client: read err={}\n", .{@intFromEnum(err.err)});
        return null;
    }

    lib.writeFmt("vfs_client: read unexpected label=0x{x}\n", .{reply.label()});
    return null;
}

fn closeFile(endpoint: Handle, fd: u32) bool {
    const req = vfs.CloseRequest{ .fd = fd };
    var msg = IpcMessage.init(@intFromEnum(vfs.VfsOp.close), PAYLOAD_WORDS);
    lib.payloadOf(&msg).* = vfs.serialize(vfs.CloseRequest, &req);

    var reply: IpcMessage = .{};
    const rc = sc.sysIpcCall(endpoint, &msg, &reply);
    if (sc.isSysErr(rc)) {
        lib.writeFmt("vfs_client: ipc_call(close) failed ret=0x{x}\n", .{rc});
        return false;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        return true;
    }

    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) {
        const err = vfs.deserialize(vfs.OpenResponse, lib.payloadOfConst(&reply));
        lib.writeFmt("vfs_client: close err={}\n", .{@intFromEnum(err.err)});
        return false;
    }

    lib.writeFmt("vfs_client: close unexpected label=0x{x}\n", .{reply.label()});
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
    sc.sysWrite(1, &line, pos);
}
