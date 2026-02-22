//! Kernel-side InitRD bootstrap.
//!
//! Responsibilities:
//! 1. Validate the initrd archive.
//! 2. Find the file marked as init server.
//! 3. Spawn it as the first user process.
//! 4. Map initrd pages into the process.
//! 5. Create and pass a VFS endpoint handle.

const std = @import("std");
const arch = @import("arch");
const mm = @import("mm");
const shared = @import("shared");
const process = @import("process/mod.zig");
const ipc = @import("ipc/mod.zig");
const task = @import("sched/task.zig");
const Task = task.Task;

const initrd = shared.initrd;
const log = shared.log;

pub const INITRD_USER_BASE: u64 = 0x0000_0080_6000_0000;

pub const BootInitrdError = error{
    InitrdNotFound,
    InvalidMagic,
    NoInitServer,
    NoVfsClient,
    ElfLoadFailed,
    ClientLoadFailed,
    InitrdMapFailed,
    EndpointCreateFailed,
};

var initrd_base: ?[*]const u8 = null;
var initrd_size: usize = 0;
var archive: ?*const initrd.ArchiveHeader = null;
var bootstrap_vfs_endpoint: ?ipc.EndpointId = null;

pub fn setInitrd(base: [*]const u8, size: usize) void {
    initrd_base = base;
    initrd_size = size;
    bootstrap_vfs_endpoint = null;
    log.info("initrd: located at 0x{x}, {d} bytes", .{ @intFromPtr(base), size });
}

pub fn validate() BootInitrdError!*const initrd.ArchiveHeader {
    const base = initrd_base orelse return BootInitrdError.InitrdNotFound;

    if (initrd_size < @sizeOf(initrd.ArchiveHeader)) {
        log.err("initrd: too small ({d} bytes)", .{initrd_size});
        return BootInitrdError.InvalidMagic;
    }

    const hdr: *const initrd.ArchiveHeader = @ptrCast(@alignCast(base));
    if (!hdr.isValid()) {
        log.err("initrd: bad magic 0x{X} (expected 0x{X})", .{ hdr.magic, initrd.MAGIC });
        return BootInitrdError.InvalidMagic;
    }

    if (hdr.total_size > initrd_size) {
        log.err("initrd: header total_size ({d}) exceeds buffer ({d})", .{ hdr.total_size, initrd_size });
        return BootInitrdError.InvalidMagic;
    }

    log.info("initrd: valid archive, {d} files, {d} bytes total", .{
        hdr.file_count,
        hdr.total_size,
    });

    for (0..hdr.file_count) |i| {
        const entry = hdr.getEntry(@intCast(i)).?;
        const flags_str: []const u8 = if (entry.flags.is_init_server)
            "[INIT]"
        else if (entry.flags.is_driver)
            "[DRIVER]"
        else if (entry.flags.is_executable)
            "[EXEC]"
        else
            "[DATA]";
        log.info("    {s}: {d} bytes {s}", .{
            entry.getName(),
            entry.data_size,
            flags_str,
        });
    }

    archive = hdr;
    return hdr;
}

pub fn bootstrap(allocator: std.mem.Allocator) BootInitrdError!*Task {
    const hdr = try validate();

    const init_entry = hdr.findInitServer() orelse {
        log.err("initrd: no file marked as init server", .{});
        return BootInitrdError.NoInitServer;
    };

    const elf_data = hdr.fileData(init_entry);
    log.info("initrd: loading init server '{s}' ({d} bytes)", .{
        init_entry.getName(),
        elf_data.len,
    });

    const proc = process.createFromElf(allocator, init_entry.getName(), elf_data, task.Priority.NORMAL_DEFAULT) catch {
        return BootInitrdError.ElfLoadFailed;
    };

    const endpoint = ipc.createEndpoint(proc.pid) catch return BootInitrdError.EndpointCreateFailed;
    const vfs_handle = ipc.handles.installEndpoint(proc.pid, endpoint) catch return BootInitrdError.EndpointCreateFailed;
    bootstrap_vfs_endpoint = endpoint;

    const base = initrd_base orelse return BootInitrdError.InitrdNotFound;
    const initrd_phys = arch.virtToPhys(@intFromPtr(base));
    const initrd_phys_page = std.mem.alignBackward(u64, initrd_phys, mm.PAGE_SIZE);
    const page_offset = initrd_phys - initrd_phys_page;
    const mapped_len = page_offset + @as(u64, @intCast(initrd_size));
    const page_count_u64 = std.math.divCeil(u64, mapped_len, mm.PAGE_SIZE) catch return BootInitrdError.InvalidMagic;
    const page_count: usize = std.math.cast(usize, page_count_u64) orelse return BootInitrdError.InvalidMagic;

    proc.addr_space.mapPages(INITRD_USER_BASE, initrd_phys_page, page_count, mm.vmm.MapFlags.user_rodata) catch {
        return BootInitrdError.InitrdMapFailed;
    };

    proc.main_task.user_arg0 = INITRD_USER_BASE + page_offset;
    proc.main_task.user_arg1 = @as(u64, @intCast(initrd_size));
    proc.main_task.user_arg2 = vfs_handle;

    return proc.main_task;
}

pub fn getBootstrapVfsEndpoint() ?ipc.EndpointId {
    return bootstrap_vfs_endpoint;
}

pub fn bootstrapTestClient(allocator: std.mem.Allocator) BootInitrdError!*Task {
    const hdr = archive orelse try validate();
    const entry = hdr.findFile("vfs_client") orelse return BootInitrdError.NoVfsClient;

    const elf_data = hdr.fileData(entry);
    log.info("initrd: loading test client '{s}' ({d} bytes)", .{
        entry.getName(),
        elf_data.len,
    });

    const proc = process.createFromElf(allocator, entry.getName(), elf_data, task.Priority.NORMAL_DEFAULT) catch {
        return BootInitrdError.ClientLoadFailed;
    };

    return proc.main_task;
}

pub fn bootstrapSyscallTest(allocator: std.mem.Allocator) BootInitrdError!*Task {
    const hdr = archive orelse try validate();
    const entry = hdr.findFile("syscall_test") orelse {
        log.warn("initrd: no syscall test binary found", .{});
        return BootInitrdError.NoVfsClient;
    };
    const elf_data = hdr.fileData(entry);
    log.info("initrd: loading syscall test '{s}' ({d} bytes)", .{
        entry.getName(), elf_data.len,
    });
    const proc = process.createFromElf(allocator, entry.getName(), elf_data, task.Priority.NORMAL_DEFAULT) catch {
        return BootInitrdError.ClientLoadFailed;
    };
    return proc.main_task;
}

pub fn bootstrapShell(allocator: std.mem.Allocator) BootInitrdError!*Task {
    const hdr = archive orelse try validate();
    const entry = hdr.findFile("shell") orelse {
        log.warn("initrd: no shell binary found", .{});
        return BootInitrdError.NoVfsClient;
    };
    const elf_data = hdr.fileData(entry);
    log.info("initrd: loading shell '{s}' ({d} bytes)", .{
        entry.getName(), elf_data.len,
    });
    const proc = process.createFromElf(allocator, entry.getName(), elf_data, task.Priority.NORMAL_DEFAULT) catch {
        return BootInitrdError.ClientLoadFailed;
    };
    return proc.main_task;
}
