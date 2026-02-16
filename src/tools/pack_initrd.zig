//! Build-Time InitRD Packer
//!
//! Packs a list of files into the ZNFS initrd format.
//!
//! Usage (standalone):
//!     zig build-exe src/tools/pack_initrd.zig ramfs_server:init ps2_driver:driver shell:exec
//!
//! File spec format: "filename:type" where type is:
//!     init    - the init/ramfs server (kernel loads this first)
//!     driver  - a device driver
//!     exec    - a regular executable
//!     data    - a data file

const std = @import("std");
const initrd = @import("shared").initrd;

const FileSpec = struct {
    path: []const u8, // path on host filesystem
    name: []const u8, // name in the archive
    flags: initrd.FileFlags,
};
var g_init: std.process.Init = undefined;
pub fn main(init: std.process.Init) !void {
    g_init = init;
    const args = init.minimal.args.toSlice(init.gpa) catch |err| {
        std.debug.print("Failed to get args slice: {any}", .{err});
        return error.FailedToGetArgsSlice;
    };
    defer init.gpa.free(args);
    var output_path: []const u8 = "initrd.img";
    var specs = std.ArrayList(FileSpec).initCapacity(init.gpa, 2048) catch |err| {
        std.debug.print("Failed to initialize array list for specs: {any}", .{err});
        return error.ArrayListInitFailed;
    };
    defer specs.deinit(init.gpa);

    var i: usize = 1;
    if (i < args.len and !std.mem.eql(u8, args[i], "-o") and parseTypeFlag(args[i]) == null and std.mem.eql(u8, std.fs.path.extension(args[i]), ".img")) {
        output_path = args[i];
        i += 1;
    }

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output_path = args[i];
        } else if (parseTypeFlag(args[i])) |type_str| {
            i += 1;
            if (i >= args.len) return error.InvalidArg;
            const spec = try parseFilePath(args[i], type_str);
            try specs.append(init.gpa, spec);
        } else {
            const spec = try parseFileSpec(args[i]);
            try specs.append(init.gpa, spec);
        }
    }

    if (specs.items.len == 0) {
        std.debug.print("Usage: pack_initrd [-o output.img] file1:type [file2:type ...]\n", .{});
        std.debug.print("Types: init, driver, exec, data\n", .{});
        return;
    }

    try packInitrd(init.gpa, output_path, specs.items);
    std.debug.print("Packed {d} files into {s}\n", .{ specs.items.len, output_path });
}

fn parseFileSpec(arg: []const u8) !FileSpec {
    // Format: "path:type" - the archive name is the basename of path
    var it = std.mem.splitScalar(u8, arg, ':');
    const path = it.next() orelse return error.InvalidArg;
    const type_str = it.next() orelse "exec";
    return parseFilePath(path, type_str);
}

fn parseTypeFlag(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "--init")) return "init";
    if (std.mem.eql(u8, arg, "--driver")) return "driver";
    if (std.mem.eql(u8, arg, "--exec")) return "exec";
    if (std.mem.eql(u8, arg, "--data")) return "data";
    return null;
}

fn parseFlags(type_str: []const u8) !initrd.FileFlags {
    return if (std.mem.eql(u8, type_str, "init"))
        .{ .is_init_server = true, .is_executable = true }
    else if (std.mem.eql(u8, type_str, "driver"))
        .{ .is_driver = true, .is_executable = true }
    else if (std.mem.eql(u8, type_str, "exec"))
        .{ .is_executable = true }
    else if (std.mem.eql(u8, type_str, "data"))
        .{ .is_data = true }
    else
        error.InvalidFileType;
}

fn parseFilePath(path: []const u8, type_str: []const u8) !FileSpec {
    const name = std.fs.path.basename(path);
    const flags = try parseFlags(type_str);

    return .{ .path = path, .name = name, .flags = flags };
}

fn packInitrd(allocator: std.mem.Allocator, output_path: []const u8, specs: []const FileSpec) !void {
    const FileData = struct { data: []const u8, spec: FileSpec };
    var files = try allocator.alloc(FileData, specs.len);
    var loaded_count: usize = 0;

    defer {
        for (0..loaded_count) |i| allocator.free(files[i].data);
        allocator.free(files);
    }

    for (specs, 0..) |spec, idx| {
        const data = try std.Io.Dir.cwd().readFileAlloc(g_init.io, spec.path, allocator, .limited(64 * 1024 * 1024));
        files[idx] = .{ .data = data, .spec = spec };
        loaded_count += 1;
    }

    const header_size: u64 = @sizeOf(initrd.ArchiveHeader);
    const table_size: u64 = @as(u64, @sizeOf(initrd.FileEntry)) * specs.len;
    const data_start = std.mem.alignForward(u64, header_size + table_size, initrd.PAGE_SIZE);

    var file_offsets = try allocator.alloc(u64, specs.len);
    defer allocator.free(file_offsets);

    var current_offset = data_start;
    for (files, 0..) |f, idx| {
        file_offsets[idx] = current_offset;
        current_offset = std.mem.alignForward(u64, current_offset + f.data.len, initrd.PAGE_SIZE);
    }

    const total_size = current_offset;

    var output = try allocator.alloc(u8, total_size);
    defer allocator.free(output);
    @memset(output, 0);

    const header: *initrd.ArchiveHeader = @ptrCast(@alignCast(output.ptr));
    header.* = .{
        .magic = initrd.MAGIC,
        .version = initrd.VERSION,
        .file_count = @intCast(specs.len),
        .total_size = total_size,
        .data_offset = data_start,
        ._reserved = 0,
    };

    const entries: [*]initrd.FileEntry = @ptrCast(@alignCast(output.ptr + @sizeOf(initrd.ArchiveHeader)));
    for (files, 0..) |f, idx| {
        var entry = &entries[idx];
        entry.* = std.mem.zeroes(initrd.FileEntry);

        const name_bytes = f.spec.name;
        if (name_bytes.len >= initrd.MAX_NAME_LEN) return error.NameTooLong;
        @memcpy(entry.name[0..name_bytes.len], name_bytes);
        entry.name[name_bytes.len] = 0;

        entry.data_offset = file_offsets[idx];
        entry.data_size = f.data.len;
        entry.flags = f.spec.flags;
    }

    for (files, 0..) |f, idx| {
        const offset: usize = @intCast(file_offsets[idx]);
        @memcpy(output[offset..][0..f.data.len], f.data);
    }

    const out_file = try std.Io.Dir.cwd().createFile(g_init.io, output_path, .{});
    defer out_file.close(g_init.io);
    try out_file.writeStreamingAll(g_init.io, output);

    std.debug.print("InitRD: {d} bytes total, {d} files\n", .{ total_size, specs.len });
    for (files, 0..) |f, idx| {
        const flag_str: []const u8 = if (f.spec.flags.is_init_server) " [INIT]" else if (f.spec.flags.is_driver)
            " [DRIVER]"
        else if (f.spec.flags.is_executable)
            " [EXEC]"
        else
            " [DATA]";
        std.debug.print("    {s}: {d} bytes @ offset 0x{X}{s}\n", .{
            f.spec.name,
            f.data.len,
            file_offsets[idx],
            flag_str,
        });
    }
}
