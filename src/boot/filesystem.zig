// Filesystem operations for UEFI

const std = @import("std");
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const File = uefi.protocol.File;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const LoadedImage = uefi.protocol.LoadedImage;

const console = @import("console.zig");

pub const FileError = error{
    NoLoadedImage,
    NoDeviceHandle,
    NoFileSystem,
    OpenVolumeFailed,
    FileNotFound,
    SeekFailed,
    GetPositionFailed,
    OutOfMemory,
    ReadFailed,
};

pub fn open_volume(boot_services: *BootServices) FileError!*File {
    console.println("[*] Opening boot volume...");

    // Get loaded image protocol to find our boot device
    const loaded_image = boot_services.handleProtocol(
        LoadedImage,
        uefi.handle,
    ) catch {
        console.println("[!] Failed to get loaded image");
        return FileError.NoLoadedImage;
    } orelse {
        console.println("[!] Loaded image protocol not found");
        return FileError.NoLoadedImage;
    };

    const device_handle = loaded_image.device_handle orelse {
        console.println("[!] No device handle");
        return FileError.NoDeviceHandle;
    };

    const fs = boot_services.handleProtocol(
        SimpleFileSystem,
        device_handle,
    ) catch {
        console.println("[!] Filesystem protocol not found");
        return FileError.NoFileSystem;
    };

    const root = fs.?.openVolume() catch {
        console.println("[!] Failed to open volume");
        return FileError.OpenVolumeFailed;
    };

    console.println("[+] Boot volume opened");
    return root;
}

pub fn load_file(boot_services: *BootServices, root: *File, path: [:0]const u16) FileError![]u8 {
    console.println("[*] Loading file...");

    const file = root.open(path, .read, .{}) catch {
        console.println("[!] Failed to open file");
        return FileError.FileNotFound;
    };
    defer file.close() catch {};

    file.setPosition(0xffff_ffff_ffff_ffff) catch {
        console.println("[!] Failed to seek to end");
        return FileError.SeekFailed;
    };

    const file_size = file.getPosition() catch {
        console.println("[!] Failed to get position");
        return FileError.GetPositionFailed;
    };

    file.setPosition(0) catch {
        console.println("[!] Failed to seek to start");
        return FileError.SeekFailed;
    };

    console.printfln("[*] File size: {d} bytes", .{file_size});

    const file_buffer = boot_services.allocatePool(
        .loader_data,
        @intCast(file_size),
    ) catch {
        console.println("[!] Failed to allocate buffer");
        return FileError.OutOfMemory;
    };

    const bytes_read = file.read(file_buffer) catch {
        console.println("[!] Failed to read file");
        return FileError.ReadFailed;
    };

    console.println("[+] File loaded successfully");
    return file_buffer[0..bytes_read];
}
