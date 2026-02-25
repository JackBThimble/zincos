pub const std = @import("std");
pub const shared = @import("shared");
pub const initrd = shared.initrd;
pub const ipc = shared.ipc_message;
pub const vfs = shared.vfs_protocol;
pub const syscall = @import("syscall.zig");

const Handle = u64;
const PAYLOAD_WORDS: u4 = @intCast(shared.ipc_message.MAX_DATA_WORDS);

pub const MAX_OPEN_FILES: usize = 64;

pub const OpenFile = struct {
    entry: *const initrd.FileEntry,
};

pub const ReaddirResult = union(enum) {
    entry: vfs.ReaddirResponse,
    end: void,
};

pub fn readdirNext(endpoint: Handle, start_index: u32) ?ReaddirResult {
    const req = vfs.ReaddirRequest{
        .fd = 0,
        .start_index = start_index,
    };

    var msg = ipc.Message.init(@intFromEnum(vfs.VfsOp.readdir), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.ReaddirRequest, &req);

    var reply: ipc.Message = .{};
    const rc = syscall.sysIpcCall(endpoint, &msg, &reply);
    if (syscall.isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.readdir_entry)) {
        const resp = vfs.deserialize(vfs.ReaddirResponse, payloadOfConst(&reply));
        return .{ .entry = resp.* };
    }
    if (reply.label() == @intFromEnum(vfs.VfsOp.readdir_end)) return .{ .end = {} };
    if (reply.label() == @intFromEnum(vfs.VfsOp.err)) return null;
    return null;
}

pub fn writeLit(comptime s: []const u8) void {
    syscall.sysWrite(1, s.ptr, s.len);
}

pub fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
    syscall.sysWrite(1, out.ptr, out.len);
}

pub fn payloadOf(msg: *ipc.Message) *[vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

pub fn payloadOfConst(msg: *const ipc.Message) *const [vfs.IPC_PAYLOAD_BYTES]u8 {
    return @ptrCast(&msg.data);
}

pub fn openFile(endpoint: Handle, name: []const u8) ?struct { fd: u32, file_size: u64 } {
    var req = std.mem.zeroes(vfs.OpenRequest);
    const name_len = @min(name.len, req.name.len - 1);
    @memcpy(req.name[0..name_len], name[0..name_len]);
    req.name[name_len] = 0;
    req.flags = .{ .read = true };

    var msg = ipc.Message.init(@intFromEnum(vfs.VfsOp.open), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.OpenRequest, &req);

    var reply: ipc.Message = .{};
    const rc = syscall.sysIpcCall(endpoint, &msg, &reply);
    if (syscall.isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.ok)) {
        const resp = vfs.deserialize(vfs.OpenResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return .{ .fd = resp.fd, .file_size = resp.file_size };
    }
    return null;
}

pub fn readChunk(endpoint: Handle, fd: u32, offset: u64, len: u64) ?vfs.ReadResponse {
    const req = vfs.ReadRequest{
        .fd = fd,
        .offset = offset,
        .length = len,
    };
    var msg = ipc.Message.init(@intFromEnum(vfs.VfsOp.read), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.ReadRequest, &req);

    var reply: ipc.Message = .{};
    const rc = syscall.sysIpcCall(endpoint, &msg, &reply);
    if (syscall.isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.read_inline)) {
        const resp = vfs.deserialize(vfs.ReadResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return resp.*;
    }
    return null;
}

pub fn statFile(endpoint: Handle, fd: u32) ?vfs.StatResponse {
    const req = vfs.StatRequest{ .fd = fd };
    var msg = ipc.Message.init(@intFromEnum(vfs.VfsOp.stat), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.StatRequest, &req);

    var reply: ipc.Message = .{};
    const rc = syscall.sysIpcCall(endpoint, &msg, &reply);
    if (syscall.isSysErr(rc)) return null;

    if (reply.label() == @intFromEnum(vfs.VfsOp.stat_data)) {
        const resp = vfs.deserialize(vfs.StatResponse, payloadOfConst(&reply));
        if (resp.err != .none) return null;
        return resp.*;
    }
    return null;
}

pub fn closeFile(endpoint: Handle, fd: u32) bool {
    const req = vfs.CloseRequest{ .fd = fd };
    var msg = ipc.Message.init(@intFromEnum(vfs.VfsOp.close), PAYLOAD_WORDS);
    payloadOf(&msg).* = vfs.serialize(vfs.CloseRequest, &req);

    var reply: ipc.Message = .{};
    const rc = syscall.sysIpcCall(endpoint, &msg, &reply);
    if (syscall.isSysErr(rc)) return false;
    return reply.label() == @intFromEnum(vfs.VfsOp.ok);
}

pub fn trimCString(buf: []const u8) []const u8 {
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

pub fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') start += 1;
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') end -= 1;
    return s[start..end];
}

pub fn firstToken(s: []const u8) []const u8 {
    var end: usize = 0;
    while (end < s.len and s[end] != ' ') end += 1;
    return s[0..end];
}

pub fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
