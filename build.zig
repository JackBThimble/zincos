const std = @import("std");

pub fn build(b: *std.Build) void {
    const efi_optimize = b.standardOptimizeOption(.{});
    const efi_target = b.resolveTargetQuery(.{
        .os_tag = .uefi,
        .cpu_arch = .x86_64,
        .abi = .msvc,
        .ofmt = .coff,
    });
    const efi_module = b.addModule("efi_module", .{
        .code_model = .default,
        .root_source_file = b.path("src/boot/main.zig"),
        .target = efi_target,
        .optimize = efi_optimize,
    });
    const efi_exe = b.addExecutable(.{
        .name = "bootx64.efi",
        .root_module = efi_module,
        .linkage = .static,
    });

    const common_module = b.addModule("common", .{
        .root_source_file = b.path("src/common.zig"),
    });

    const arch_module = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
        }),
    });
    arch_module.addImport("common", common_module);

    const kernel_optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });
    const kernel_target = b.resolveTargetQuery(.{ .os_tag = .freestanding, .ofmt = .elf, .cpu_arch = .x86_64 });
    const kernel_module = b.addModule("kernel_module", .{
        .code_model = .kernel,
        .root_source_file = b.path("src/kernel/main.zig"),
        .optimize = kernel_optimize,
        .target = kernel_target,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .omit_frame_pointer = true,
    });
    kernel_module.addImport("arch", arch_module);
    kernel_module.addImport("common", common_module);

    // Build ISR assembly
    const isr_asm = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
    isr_asm.addArg("-o");
    const isr_obj = isr_asm.addOutputFileArg("isr.o");
    isr_asm.addFileArg(b.path("src/arch/x86_64/interrupts/isr.asm"));

    const gdt_asm = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
    gdt_asm.addArg("-o");
    const gdt_obj = gdt_asm.addOutputFileArg("gdt.o");
    gdt_asm.addFileArg(b.path("src/arch/x86_64/gdt_load.asm"));

    // Compile kernel to object file (not executable)
    const kernel_obj = b.addObject(.{
        .name = "kernel",
        .root_module = kernel_module,
    });
    kernel_obj.root_module.addObjectFile(isr_obj);
    kernel_obj.root_module.addObjectFile(gdt_obj);

    // Link with system ld.lld using our linker script (bypasses Zig's broken LLD integration)
    const link_cmd = b.addSystemCommand(&.{"ld.lld"});
    link_cmd.addArg("-T");
    link_cmd.addFileArg(b.path("src/kernel/linker.ld"));
    link_cmd.addArg("-o");
    const kernel_elf = link_cmd.addOutputFileArg("ZincOS");
    link_cmd.addArtifactArg(kernel_obj);

    // Add Zig's compiler-rt builtins (memcpy, memmove, etc.)
    const builtin_obj = b.addObject(.{
        .name = "compiler_rt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/builtins.zig"),
            .target = kernel_target,
            .optimize = kernel_optimize,
            .pic = false,
            .red_zone = false,
        }),
    });
    link_cmd.addArtifactArg(builtin_obj);

    const out_dir_name = "img";
    const install_efi = b.addInstallFile(
        efi_exe.getEmittedBin(),
        b.fmt("{s}/efi/boot/{s}", .{ out_dir_name, efi_exe.name }),
    );

    install_efi.step.dependOn(&efi_exe.step);
    b.getInstallStep().dependOn(&install_efi.step);

    const install_kernel = b.addInstallFile(kernel_elf, b.fmt("{s}/efi/{s}", .{ out_dir_name, "ZincOS" }));
    install_kernel.step.dependOn(&link_cmd.step);
    b.getInstallStep().dependOn(&install_kernel.step);

    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-m",
        "1G",
        "-bios",
        "/usr/share/ovmf/x64/OVMF.4m.fd",
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-serial",
        "mon:stdio",
        "-no-reboot",
        "-enable-kvm",
        "-cpu",
        "host",
        "-s",
    };
    const qemu_cmd = b.addSystemCommand(&qemu_args);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_qemu_cmd = b.step("run", "Run QMEU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);
}
