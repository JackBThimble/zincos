//! VFS IPC Protocol
//!
//! Defines the message format for file operations over IPC.
//! Shared between the ramfs server and all client processes.
//!
//! Client                              RamFS Server
//!     |                                   |
//!     |-- VFS_OPEN("shell")-------------->|
//!     |<-- OPEN_OK(fd=3, size=48000) -----|
//!     |                                   |
//!     |-- VFS_READ(fd=3, off=0, 4096) --->|
//!     |<-- READ_OK(bytes_read=4096) ------|
//!     |                                   |
//!     |-- VFS_READ(fd=3, off=4096, ...) ->|
//!     |-- READ_OK(bytes_read=4096) -------|
//!     |   ...                             |
//!     |-- VFS_CLOSE(fd=3) --------------->|
//!     |<-- CLOSE_OK ----------------------|
//!
//! Current milestone behavior:
//! - Read responses are returned inline (`VfsOp.read_inline`).
//! - `VfsOp.read_data` is reserved for a later shared-memory fast path.

/// VFS operation codes - stored in the message label field.
pub const VfsOp = enum(u32) {
    // -- Requests (client -> server) --
    open = 0x0001,
    close = 0x0002,
    read = 0x0003,
    write = 0x0004, // not supported for ramfs (read-only initrd)
    stat = 0x0005,
    readdir = 0x0006,

    // -- Responses (server -> client) --
    ok = 0x8001,
    err = 0x8002,
    read_data = 0x8003, // bulk read response (data in shared memory)
    read_inline = 0x8004, // small read response (data in message)
    stat_data = 0x8005,
    readdir_entry = 0x8006,
    readdir_end = 0x8007,
};

/// Error codes returned by the VFS server.
pub const VfsError = enum(u32) {
    none = 0,
    not_found = 1,
    permission_denied = 2,
    invalid_fd = 3,
    not_a_directory = 4,
    io_error = 5,
    no_space = 6,
    read_only = 7,
    name_too_long = 8,
    invalid_op = 9,
    buf_too_small = 10,
};

pub const IPC_PAYLOAD_BYTES = 48;

/// VFS_OPEN request - open a file by name.
/// Message label: VfsOp.open
pub const OpenRequest = extern struct {
    /// Null-terminated filename (max 39 chars + null).
    /// For paths: "bin/shell", "drivers/ps2", "config.txt"
    name: [40]u8,
    /// Open flags (read, write, create, etc.)
    flags: OpenFlags,
    _pad: u32 = 0,

    pub const OpenFlags = packed struct(u32) {
        read: bool = true,
        write: bool = false,
        create: bool = false,
        truncate: bool = false,
        _reserved: u28 = 0,
    };
};

/// VFS_OPEN response - returns a file descriptor.
/// Message label: VfsOp.ok (on success) or VfsOp.err (on failure)
pub const OpenResponse = extern struct {
    /// File descriptor (server-assigned, opaque to client).
    fd: u32,
    /// Total file size in bytes.
    file_size: u64,
    /// Error code (VfsError.none on success).
    err: VfsError,
    _pad: [28]u8 = [_]u8{0} ** 28,
};

/// VFS_READ request - read data from an open file.
/// Message label: VfsOp.read
pub const ReadRequest = extern struct {
    /// File descriptor from OpenResponse.
    fd: u32,
    _pad: u32 = 0,
    /// Byte offset to start reading from.
    offset: u64,
    /// Number of bytes to read.
    length: u64,
    _pad1: [24]u8 = [_]u8{0} ** 24,
};

/// VFS_READ response - result of a read operation.
/// Message label: VfsOp.read_inline (current milestone)
pub const ReadResponse = extern struct {
    /// Number of bytes actually read (0 = EOF).
    bytes_read: u64,
    /// Error code,
    err: VfsError,
    _pad0: u32 = 0,
    /// For read_inline: the actual data (up to 32 bytes).
    /// Only valid when label == VfsOp.read_inline.
    inline_data: [32]u8,
};

/// VFS_CLOSE request - close a file descritor.
/// Message label: VfsOp.close()
pub const CloseRequest = extern struct {
    fd: u32,
    _pad: [44]u8 = [_]u8{0} ** 44,
};

/// VFS_STAT request - get file metadata.
/// Message label: VfsOp.stat
pub const StatRequest = extern struct {
    fd: u32,
    _pad: [44]u8 = [_]u8{0} ** 44,
};

/// VFS_STAT response.
/// Message label: VfsOp.stat_data
pub const StatResponse = extern struct {
    file_size: u64,
    flags: u32,
    err: VfsError,
    _pad: [32]u8 = [_]u8{0} ** 32,
};

/// VFS_READDIR request - list directory contents.
/// Message label: VfsOp.readdir
pub const ReaddirRequest = extern struct {
    /// Directory fd (for ramfs, just use fd=0 for root).
    fd: u32,
    /// Index to start from (for pagination).
    start_index: u32,
    _pad: [40]u8 = [_]u8{0} ** 40,
};

/// VFS_READDIR response - one directory entry.
/// Message label: VfsOp.readdir_entry (more entries) or VfsOp.readdir_end (done)
pub const ReaddirResponse = extern struct {
    /// Entry index.
    index: u32,
    /// File size.
    file_size: u32,
    /// Null-terminated filename.
    name: [40]u8,
};

pub fn serialize(comptime T: type, msg: *const T) [IPC_PAYLOAD_BYTES]u8 {
    comptime {
        if (@sizeOf(T) > IPC_PAYLOAD_BYTES) @compileError("VFS message too large for IPC payload");
    }
    var buf: [IPC_PAYLOAD_BYTES]u8 = [_]u8{0} ** IPC_PAYLOAD_BYTES;
    const bytes: [*]const u8 = @ptrCast(msg);
    @memcpy(buf[0..@sizeOf(T)], bytes[0..@sizeOf(T)]);
    return buf;
}

/// Deserialize an IPC payload.
pub fn deserialize(comptime T: type, payload: *const [IPC_PAYLOAD_BYTES]u8) *const T {
    return @ptrCast(@alignCast(payload));
}

// Compile time checks: all messages must fit in the IPC payload.
comptime {
    if (@sizeOf(OpenRequest) > IPC_PAYLOAD_BYTES) @compileError("OpenRequest too large");
    if (@sizeOf(OpenResponse) > IPC_PAYLOAD_BYTES) @compileError("OpenResponse too large");
    if (@sizeOf(ReadRequest) > IPC_PAYLOAD_BYTES) @compileError("ReadRequest too large");
    if (@sizeOf(ReadResponse) > IPC_PAYLOAD_BYTES) @compileError("ReadResponse too large");
    if (@sizeOf(CloseRequest) > IPC_PAYLOAD_BYTES) @compileError("CloseRequest too large");
    if (@sizeOf(StatRequest) > IPC_PAYLOAD_BYTES) @compileError("StatRequest too large");
    if (@sizeOf(StatResponse) > IPC_PAYLOAD_BYTES) @compileError("StatResponse too large");
    if (@sizeOf(ReaddirRequest) > IPC_PAYLOAD_BYTES) @compileError("ReaddirRequest too large");
    if (@sizeOf(ReaddirResponse) > IPC_PAYLOAD_BYTES) @compileError("ReaddirResponse too large");
}
