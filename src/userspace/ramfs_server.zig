//! Minimal userspace RamFS server backed by initrd.

const std = @import("std");
const shared = @import("shared");

const initrd = shared.initrd;
const vfs = shared.vfs_protocol;
const sc = shared.syscall;
const IpcMessage = shared.ipc_message.Message;

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(shared.ipc_message.MAX_DATA_WORDS);
const MAX_OPEN_FILES: usize = 64;

const OpenFile = struct {
    entry: *const initrd.FileEntry,
};

var g_archive: ?*const initrd.ArchiveHeader = null;
var g_open: [MAX_OPEN_FILES]?OpenFile = [_]?OpenFile{null} ** MAX_OPEN_FILES;

pub export fn _start(initrd_addr: usize, initrd_size: usize, vfs_endpoint: Handle) callconv(.c) noreturn {
    const base: [*]const u8 = @ptrFromInt(initrd_addr);
    if (initrd_size < @sizeOf(initrd.ArchiveHeader)) hang();

    const hdr: *const initrd.ArchiveHeader = @ptrCast(@alignCast(base));
    if (!hdr.isValid()) hang();
    if (hdr.total_size > initrd_size) hang();

    g_archive = hdr;
    run(vfs_endpoint);
}

fn run(endpoint: Handle) noreturn {
    while (true) {
        var req: IpcMessage = .{};
        var caller: Handle = 0;

        const rc = sysIpcReceive(endpoint, &req, &caller);
        if (isSysErr(rc) or caller == 0) {
            sysSchedYield();
            continue;
        }

        const reply = handleRequest(&req);
        _ = sysIpcReply(caller, &reply);
    }
}

fn handleRequest(req_msg: *const IpcMessage) IpcMessage {
    const label = req_msg.label();
    return switch (label) {
        @intFromEnum(vfs.VfsOp.open) => handleOpen(req_msg),
        @intFromEnum(vfs.VfsOp.read) => handleRead(req_msg),
        @intFromEnum(vfs.VfsOp.close) => handleClose(req_msg),
        @intFromEnum(vfs.VfsOp.stat) => handleStat(req_msg),
        else => makeErrorReply(vfs.VfsError.invalid_op),
    };
}

fn handleOpen(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.OpenRequest, payloadOfConst(req_msg));
    const name = trimCString(req.name[0..]);
    const hdr = g_archive orelse return makeErrorReply(vfs.VfsError.io_error);
    const entry = hdr.findFile(name) orelse return makeErrorReply(vfs.VfsError.not_found);
    const fd = allocFd(entry) orelse return makeErrorReply(vfs.VfsError.no_space);

    var resp = vfs.OpenResponse{
        .fd = fd,
        .file_size = entry.data_size,
        .err = .none,
    };

    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.ok), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.OpenResponse, &resp);
    return reply;
}

fn handleRead(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.ReadRequest, payloadOfConst(req_msg));
    const fd: u32 = req.fd;
    const open = lookupFd(fd) orelse return makeErrorRead(vfs.VfsError.invalid_fd);
    const hdr = g_archive orelse return makeErrorRead(vfs.VfsError.io_error);

    const data = hdr.fileData(open.entry);
    const offset: usize = std.math.cast(usize, req.offset) orelse return makeErrorRead(vfs.VfsError.invalid_op);
    const requested: usize = std.math.cast(usize, req.length) orelse return makeErrorRead(vfs.VfsError.invalid_op);

    var resp = vfs.ReadResponse{
        .bytes_read = 0,
        .err = .none,
        .inline_data = [_]u8{0} ** 32,
    };

    if (offset < data.len and requested != 0) {
        const available = data.len - offset;
        const to_copy = @min(@min(available, requested), resp.inline_data.len);
        @memcpy(resp.inline_data[0..to_copy], data[offset..][0..to_copy]);
        resp.bytes_read = to_copy;
    }

    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.read_inline), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.ReadResponse, &resp);
    return reply;
}

fn handleClose(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.CloseRequest, payloadOfConst(req_msg));
    if (!freeFd(req.fd)) {
        return makeErrorReply(vfs.VfsError.invalid_fd);
    }

    return IpcMessage.init(@intFromEnum(vfs.VfsOp.ok), 0);
}

fn handleStat(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.StatRequest, payloadOfConst(req_msg));
    const open = lookupFd(req.fd) orelse return makeErrorStat(vfs.VfsError.invalid_fd);

    const flags_bits: u32 = @bitCast(open.entry.flags);
    var resp = vfs.StatResponse{
        .file_size = open.entry.data_size,
        .flags = flags_bits,
        .err = .none,
    };

    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.stat_data), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.StatResponse, &resp);
    return reply;
}

fn makeErrorReply(err: vfs.VfsError) IpcMessage {
    var resp = vfs.OpenResponse{
        .fd = 0,
        .file_size = 0,
        .err = err,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.OpenResponse, &resp);
    return reply;
}

fn makeErrorRead(err: vfs.VfsError) IpcMessage {
    var resp = vfs.ReadResponse{
        .bytes_read = 0,
        .err = err,
        .inline_data = [_]u8{0} ** 32,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.ReadResponse, &resp);
    return reply;
}

fn makeErrorStat(err: vfs.VfsError) IpcMessage {
    var resp = vfs.StatResponse{
        .file_size = 0,
        .flags = 0,
        .err = err,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    payloadOf(&reply).* = vfs.serialize(vfs.StatResponse, &resp);
    return reply;
}

fn trimCString(buf: []const u8) []const u8 {
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

fn allocFd(entry: *const initrd.FileEntry) ?u32 {
    // fd 0 is reserved.
    for (1..MAX_OPEN_FILES) |idx| {
        if (g_open[idx] == null) {
            g_open[idx] = .{ .entry = entry };
            return @intCast(idx);
        }
    }
    return null;
}

fn lookupFd(fd: u32) ?OpenFile {
    const idx: usize = fd;
    if (idx == 0 or idx >= MAX_OPEN_FILES) return null;
    return g_open[idx];
}

fn freeFd(fd: u32) bool {
    const idx: usize = fd;
    if (idx == 0 or idx >= MAX_OPEN_FILES) return false;
    if (g_open[idx] == null) return false;
    g_open[idx] = null;
    return true;
}

fn payloadOf(msg: *IpcMessage) *[vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

fn payloadOfConst(msg: *const IpcMessage) *const [vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

fn isSysErr(ret: u64) bool {
    return @as(i64, @bitCast(ret)) < 0;
}

fn sysIpcReceive(endpoint: Handle, out_msg: *IpcMessage, out_caller: *Handle) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_receive)),
          [ep] "{rdi}" (endpoint),
          [msg] "{rsi}" (@as(u64, @intCast(@intFromPtr(out_msg)))),
          [caller] "{rdx}" (@as(u64, @intCast(@intFromPtr(out_caller)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysIpcReply(caller: Handle, msg: *const IpcMessage) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.ipc_reply)),
          [caller] "{rdi}" (caller),
          [msg] "{rsi}" (@as(u64, @intCast(@intFromPtr(msg)))),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn sysSchedYield() void {
    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (@intFromEnum(sc.Number.sched_yield)),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn hang() noreturn {
    while (true) {
        sysSchedYield();
    }
}
