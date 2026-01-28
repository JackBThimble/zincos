const std = @import("std");

pub fn build(b: *std.Build) void {
    // ===============================
    //
    // Optimization options
    //
    // ===============================
    const efi_optimize = b.standardOptimizeOption(.{});
    const kernel_optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // =========================================================================
    //
    // Targets
    //
    // =========================================================================
    const efi_target = b.resolveTargetQuery(.{
        .os_tag = .uefi,
        .cpu_arch = .x86_64,
        .abi = .msvc,
        .ofmt = .coff,
    });
    const kernel_target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .ofmt = .elf,
        .cpu_arch = .x86_64,
    });

    // =========================================================================
    //
    // Modules
    //
    // =========================================================================

    // bootloader module
    const efi_module = b.addModule("efi_module", .{
        .code_model = .default,
        .root_source_file = b.path("src/boot/main.zig"),
        .target = efi_target,
        .optimize = efi_optimize,
    });

    // Common HAL layer
    const common_module = b.addModule("common", .{
        .root_source_file = b.path("src/common/main.zig"),
    });

    // SMP trampoline as flat binary (no relocations) - must be before arch_module
    const smp_trampoline_asm = b.addSystemCommand(&.{ "nasm", "-f", "bin", "-o" });
    const smp_bin = smp_trampoline_asm.addOutputFileArg("smp_trampoline.bin");
    smp_trampoline_asm.addFileArg(b.path("src/arch/x86_64/smp_trampoline.asm"));

    // Create a wrapper module that embeds the trampoline binary
    const smp_wrapper = b.addWriteFiles();
    _ = smp_wrapper.addCopyFile(smp_bin, "smp_trampoline.bin");
    const smp_embed_zig = smp_wrapper.add("smp_trampoline_embed.zig",
        \\pub const data: []const u8 = @embedFile("smp_trampoline.bin");
    );

    // Architecture specific
    const arch_module = b.createModule(.{
        .root_source_file = b.path("src/arch/arch.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
        }),
    });

    // Add trampoline binary wrapper as anonymous import to arch module
    arch_module.addAnonymousImport("smp_trampoline_bin", .{
        .root_source_file = smp_embed_zig,
    });

    // Memory management module
    const memory_module = b.createModule(.{
        .root_source_file = b.path("src/mm/main.zig"),
    });

    // Kernel module
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

    // =========================================================================
    //
    // Imports
    //
    // =========================================================================
    memory_module.addImport("common", common_module);
    memory_module.addImport("arch", arch_module);
    arch_module.addImport("mm", memory_module);
    arch_module.addImport("common", common_module);

    kernel_module.addImport("arch", arch_module);
    kernel_module.addImport("common", common_module);
    kernel_module.addImport("mm", memory_module);

    // =========================================================================
    //
    // NASM Builds
    //
    // =========================================================================
    const isr_asm = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
    isr_asm.addArg("-o");
    const gdt_asm = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
    gdt_asm.addArg("-o");

    // =========================================================================
    //
    // Objects
    //
    // =========================================================================
    const isr_obj = isr_asm.addOutputFileArg("isr.o");
    isr_asm.addFileArg(b.path("src/arch/x86_64/interrupts/isr.asm"));
    const gdt_obj = gdt_asm.addOutputFileArg("gdt.o");
    gdt_asm.addFileArg(b.path("src/arch/x86_64/gdt_load.asm"));

    // Compile kernel to object file (not executable)
    const kernel_obj = b.addObject(.{
        .name = "kernel",
        .root_module = kernel_module,
    });
    kernel_obj.root_module.addObjectFile(isr_obj);
    kernel_obj.root_module.addObjectFile(gdt_obj);

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

    // =========================================================================
    //
    // Linker
    //
    // =========================================================================

    // Link with system ld.lld using our linker script
    // (bypasses Zig's broken LLD integration)
    const link_cmd = b.addSystemCommand(&.{"ld.lld"});

    // Kernel linking
    link_cmd.addArg("-T");
    link_cmd.addFileArg(b.path("src/kernel/linker.ld"));

    // Output file MUST come before input objects
    link_cmd.addArg("-o");
    const kernel_elf = link_cmd.addOutputFileArg("ZincOS");

    // Input object files
    link_cmd.addArtifactArg(kernel_obj);
    link_cmd.addArtifactArg(builtin_obj);

    // =========================================================================
    //
    // Executables
    //
    // =========================================================================

    // UEFI application
    const efi_exe = b.addExecutable(.{
        .name = "bootx64.efi",
        .root_module = efi_module,
        .linkage = .static,
    });

    // =========================================================================
    //
    // Installation files
    //
    // =========================================================================

    // Ouput directory for fat img (for QEMU)
    const out_dir_name = "img";

    // UEFI application at img/efi/boot/bootx64.efi
    const install_efi = b.addInstallFile(
        efi_exe.getEmittedBin(),
        b.fmt("{s}/efi/boot/{s}", .{ out_dir_name, efi_exe.name }),
    );

    // Kernel written to img directory
    const install_kernel = b.addInstallFile(kernel_elf, b.fmt("{s}/efi/{s}", .{
        out_dir_name,
        "ZincOS",
    }));

    // Kernel written to zig-out/bin/ZincOS
    const install_debug_kernel = b.addInstallBinFile(kernel_elf, b.fmt(
        "{s}",
        .{"ZincOS"},
    ));

    // =========================================================================
    //
    // Installation steps
    //
    // =========================================================================

    // Install bootx64.efi
    install_efi.step.dependOn(&efi_exe.step);
    b.getInstallStep().dependOn(&install_efi.step);

    // Install kernel
    install_kernel.step.dependOn(&link_cmd.step);
    b.getInstallStep().dependOn(&install_kernel.step);

    b.getInstallStep().dependOn(&install_debug_kernel.step);

    // ==========================================================================
    //
    // Run commands arguments
    //
    // ==========================================================================
    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-enable-kvm",
        "-no-reboot",
        "-cpu",
        "host",
        "-serial",
        "stdio",
        "-m",
        "1G",
        "-bios",
        "/usr/share/ovmf/x64/OVMF.4m.fd",
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-smp",
        "4",
    };

    const debug_qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-m",
        "1G",
        "-smp",
        "4",
        "-bios",
        "/usr/share/ovmf/x64/OVMF.4m.fd",
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-serial",
        "mon:stdio",
        "-no-reboot",
        "-no-shutdown",
        "-S",
        "-gdb",
        "tcp::1234",
        "-cpu",
        "qemu64",
        "-d",
        "cpu_reset,int,guest_errors",
    };

    // =========================================================================
    //
    // Run commands
    //
    // =========================================================================
    const qemu_cmd = b.addSystemCommand(&qemu_args);
    const run_qemu_cmd = b.step("run", "Run QMEU");
    const debug_qemu_cmd = b.addSystemCommand(&debug_qemu_args);
    const run_debug_cmd = b.step("debug", "Debug QEMU");

    qemu_cmd.step.dependOn(b.getInstallStep());
    debug_qemu_cmd.step.dependOn(b.getInstallStep());

    run_qemu_cmd.dependOn(&qemu_cmd.step);
    run_debug_cmd.dependOn(&debug_qemu_cmd.step);
}
