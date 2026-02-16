//! InitRD Archive Format
//!
//! Dead-simple archive format for packing user-space binaries into the kernel
//! image.
//!
//! Format (all little-endian):
//!
//!         _____________________________________
//!         |   ArchiveHeader (32 bytes)        | magic, version, file, count, total
//!         |-----------------------------------|
//!         | FileEntry[0] (280 bytes)          | name, offset, size, flags
//!         | FileEntry[1]                      |
//!         | ...                               |
//!         | FileEntry[N-1]                    |
//!         |-----------------------------------|
//!         | File data (packed, page-aligned)  |   actual file contents back to back
//!         | ...                               |
//!         |___________________________________|
//!
//! The file table is at a fixed offset right after the archive header,
//! so you can index into it without parsing the whole thing. File data
//! is page-aligned so it can map directly into user-space without copying.
//!
//! This file is shared between:
//!     - the build-time packing tool (pack_initrd.zig or a build.zig step)
//!     - The kernel bootstrap code (finds and loads the ramfs server)
//!     - The ramfs server (serves files over IPC)

/// Magic number: "ZNFS" in little-endian.
pub const MAGIC: u32 = 0x53464e5a;

/// Current format version.
pub const VERSION: u16 = 1;

/// Page size for alignment. Must match kernel's PAGE_SIZE;
pub const PAGE_SIZE: u32 = 4096;

/// Maximum filename length (including null terminator).
pub const MAX_NAME_LEN: usize = 256;

/// File type flags.
pub const FileFlags = packed struct(u32) {
    /// This is the ramfs/vfs server - kernel loads it directly at boot.
    is_init_server: bool = false,
    /// This is a device driver,
    is_driver: bool = false,
    /// Executable (has ELF header)
    is_executable: bool = false,
    /// Read-only data file,
    is_data: bool = false,
    _reserved: u28 = 0,
};

/// Archive header - first 32 bytes of the intrd blob.
pub const ArchiveHeader = extern struct {
    /// Must be MAGIC,
    magic: u32,
    /// Format version
    version: u16,
    /// Number of files in the archive
    file_count: u16,
    /// Total size of the archive in bytes (header + entries + data).
    total_size: u64,
    /// Offset from start of archive to the first file's data.
    /// (i.e., size of header + file table)
    data_offset: u64,
    /// Reserved for future use.
    _reserved: u32,

    pub fn isValid(self: *const ArchiveHeader) bool {
        return self.magic == MAGIC and self.version == VERSION;
    }

    /// Pointer to the file entry table (immediately after this header).
    pub fn fileEntries(self: *const ArchiveHeader) [*]const FileEntry {
        const base: [*]const u8 = @ptrCast(self);
        const entries_ptr = base + @sizeOf(ArchiveHeader);
        return @ptrCast(@alignCast(entries_ptr));
    }

    /// Get a specific file entry by index.
    pub fn getEntry(self: *const ArchiveHeader, index: u16) ?*const FileEntry {
        if (index >= self.file_count) return null;
        return &self.fileEntries()[index];
    }

    /// Find a file by name. Linear scan - fine for boot, the ramfs server
    /// can build a hash map later.
    pub fn findFile(self: *const ArchiveHeader, name: []const u8) ?*const FileEntry {
        const entries = self.fileEntries();
        for (0..self.file_count) |i| {
            const entry = &entries[i];
            const entry_name = entry.getName();
            if (std.mem.eql(u8, entry_name, name)) {
                return entry;
            }
        }
        return null;
    }

    /// Find the init server (the process the kernel boots first).
    pub fn findInitServer(self: *const ArchiveHeader) ?*const FileEntry {
        const entries = self.fileEntries();
        for (0..self.file_count) |i| {
            const entry = &entries[i];
            if (entry.flags.is_init_server) {
                return entry;
            }
        }
        return null;
    }

    /// Get a pointer to a file's data given an entry.
    pub fn fileData(self: *const ArchiveHeader, entry: *const FileEntry) []const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base[entry.data_offset..][0..entry.data_size];
    }
};

/// File entry - describes one file in the archive.
/// Fixed size (280 bytes) for easy indexing.
pub const FileEntry = extern struct {
    /// Null-terminated filename (e.g., "ramfs_server", "ps2_driver", "init").
    /// No paths - flat namespace. For directories, the ramfs server
    /// can parse a naming convention like "bin/shell" stored as the name.
    name: [MAX_NAME_LEN]u8,

    /// Byte offset from the start of the archive to this file's data
    data_offset: u64,

    /// Size of the file data in bytes.
    data_size: u64,

    /// File type / role flags.
    flags: FileFlags,

    /// Reserved padding to keep the struct a clean size.
    _reserved: u32,

    /// Get the filename as a Zig slice (up to the null terminator).
    pub fn getName(self: *const FileEntry) []const u8 {
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }

        return &self.name;
    }
};

const std = @import("std");

// Compile-time sanity checks
comptime {
    if (@sizeOf(ArchiveHeader) != 32) @compileError("ArchiveHeader size mismatch");
    if (@sizeOf(FileEntry) != 280) @compileError("FileEntry size mismatch");
}
