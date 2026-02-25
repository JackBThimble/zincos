//! Minimal userspace RamFS server backed by initrd.

const std = @import("std");
const lib = @import("lib");

const initrd = lib.initrd;
const ipc = lib.ipc;
const vfs = lib.vfs;
const sc = lib.syscall;
const IpcMessage = lib.ipc.Message;

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(ipc.MAX_DATA_WORDS);

var g_archive: ?*const initrd.ArchiveHeader = null;
var g_open: [lib.MAX_OPEN_FILES]?lib.OpenFile = [_]?lib.OpenFile{null} ** lib.MAX_OPEN_FILES;

pub export fn _start(initrd_addr: usize, initrd_size: usize, vfs_endpoint: Handle) callconv(.c) noreturn {
    const base: [*]const u8 = @ptrFromInt(initrd_addr);
    if (initrd_size < @sizeOf(initrd.ArchiveHeader)) lib.syscall.hang();

    const hdr: *const initrd.ArchiveHeader = @ptrCast(@alignCast(base));
    if (!hdr.isValid()) lib.syscall.hang();
    if (hdr.total_size > initrd_size) lib.syscall.hang();

    g_archive = hdr;
    run(vfs_endpoint);
}

fn run(endpoint: Handle) noreturn {
    while (true) {
        var req: IpcMessage = .{};
        var caller: Handle = 0;

        const rc = lib.syscall.sysIpcReceive(endpoint, &req, &caller);
        if (lib.syscall.isSysErr(rc) or caller == 0) {
            lib.syscall.sysSchedYield();
            continue;
        }

        const reply = handleRequest(&req);
        _ = lib.syscall.sysIpcReply(caller, &reply);
    }
}

fn handleRequest(req_msg: *const IpcMessage) IpcMessage {
    const label = req_msg.label();
    return switch (label) {
        @intFromEnum(vfs.VfsOp.open) => handleOpen(req_msg),
        @intFromEnum(vfs.VfsOp.read) => handleRead(req_msg),
        @intFromEnum(vfs.VfsOp.close) => handleClose(req_msg),
        @intFromEnum(vfs.VfsOp.stat) => handleStat(req_msg),
        @intFromEnum(vfs.VfsOp.readdir) => handleReaddir(req_msg),
        else => makeErrorReply(vfs.VfsError.invalid_op),
    };
}

fn handleOpen(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.OpenRequest, lib.payloadOfConst(req_msg));
    const name = lib.trimCString(req.name[0..]);
    const hdr = g_archive orelse return makeErrorReply(vfs.VfsError.io_error);
    const entry = hdr.findFile(name) orelse return makeErrorReply(vfs.VfsError.not_found);
    const fd = allocFd(entry) orelse return makeErrorReply(vfs.VfsError.no_space);

    var resp = vfs.OpenResponse{
        .fd = fd,
        .file_size = entry.data_size,
        .err = .none,
    };

    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.ok), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.OpenResponse, &resp);
    return reply;
}

fn handleRead(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.ReadRequest, lib.payloadOfConst(req_msg));
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
    lib.payloadOf(&reply).* = vfs.serialize(vfs.ReadResponse, &resp);
    return reply;
}

fn handleClose(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.CloseRequest, lib.payloadOfConst(req_msg));
    if (!freeFd(req.fd)) {
        return makeErrorReply(vfs.VfsError.invalid_fd);
    }

    return IpcMessage.init(@intFromEnum(vfs.VfsOp.ok), 0);
}

fn handleStat(req_msg: *const IpcMessage) IpcMessage {
    const req = vfs.deserialize(vfs.StatRequest, lib.payloadOfConst(req_msg));
    const open = lookupFd(req.fd) orelse return makeErrorStat(vfs.VfsError.invalid_fd);

    const flags_bits: u32 = @bitCast(open.entry.flags);
    var resp = vfs.StatResponse{
        .file_size = open.entry.data_size,
        .flags = flags_bits,
        .err = .none,
    };

    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.stat_data), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.StatResponse, &resp);
    return reply;
}

fn handleReaddir(req_msg: *const ipc.Message) ipc.Message {
    const req = vfs.deserialize(vfs.ReaddirRequest, lib.payloadOfConst(req_msg));
    if (req.fd != 0) return makeErrorReply(vfs.VfsError.not_a_directory);

    const hdr = g_archive orelse return makeErrorReply(vfs.VfsError.io_error);
    if (req.start_index >= @as(u32, hdr.file_count)) {
        return ipc.Message.init(@intFromEnum(vfs.VfsOp.readdir_end), 0);
    }

    const entry_index: u16 = std.math.cast(u16, req.start_index) orelse {
        return makeErrorReply(vfs.VfsError.invalid_op);
    };
    const entry = hdr.getEntry(entry_index) orelse {
        return ipc.Message.init(@intFromEnum(vfs.VfsOp.readdir_end), 0);
    };

    var resp = vfs.ReaddirResponse{
        .index = req.start_index,
        .file_size = std.math.cast(u32, entry.data_size) orelse std.math.maxInt(u32),
        .name = [_]u8{0} ** 40,
    };

    const src_name = entry.getName();
    const n = @min(src_name.len, resp.name.len - 1);
    @memcpy(resp.name[0..n], src_name[0..n]);
    resp.name[n] = 0;

    var reply = ipc.Message.init(@intFromEnum(vfs.VfsOp.readdir_entry), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.ReaddirResponse, &resp);
    return reply;
}

fn makeErrorReply(err: vfs.VfsError) IpcMessage {
    var resp = vfs.OpenResponse{
        .fd = 0,
        .file_size = 0,
        .err = err,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.OpenResponse, &resp);
    return reply;
}

fn makeErrorRead(err: vfs.VfsError) IpcMessage {
    var resp = vfs.ReadResponse{
        .bytes_read = 0,
        .err = err,
        .inline_data = [_]u8{0} ** 32,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.ReadResponse, &resp);
    return reply;
}

fn makeErrorStat(err: vfs.VfsError) IpcMessage {
    var resp = vfs.StatResponse{
        .file_size = 0,
        .flags = 0,
        .err = err,
    };
    var reply = IpcMessage.init(@intFromEnum(vfs.VfsOp.err), PAYLOAD_WORDS);
    lib.payloadOf(&reply).* = vfs.serialize(vfs.StatResponse, &resp);
    return reply;
}

fn allocFd(entry: *const initrd.FileEntry) ?u32 {
    // fd 0 is reserved.
    for (1..lib.MAX_OPEN_FILES) |idx| {
        if (g_open[idx] == null) {
            g_open[idx] = .{ .entry = entry };
            return @intCast(idx);
        }
    }
    return null;
}

fn lookupFd(fd: u32) ?lib.OpenFile {
    const idx: usize = fd;
    if (idx == 0 or idx >= lib.MAX_OPEN_FILES) return null;
    return g_open[idx];
}

fn freeFd(fd: u32) bool {
    const idx: usize = fd;
    if (idx == 0 or idx >= lib.MAX_OPEN_FILES) return false;
    if (g_open[idx] == null) return false;
    g_open[idx] = null;
    return true;
}
