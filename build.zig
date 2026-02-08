const std = @import("std");

pub fn build(b: *std.Build) void {
    // Optimize options
    const efi_optimize = b.standardOptimizeOption(.{});
    const kernel_optimize =
        b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // Targets
    const efi_target = b.resolveTargetQuery(.{
        .os_tag = .uefi,
        .cpu_arch = .x86_64,
        .abi = .msvc,
        .ofmt = .coff,
    });

    const kernel_target = b.resolveTargetQuery(.{ .os_tag = .freestanding, .ofmt = .elf, .cpu_arch = .x86_64 });

    // Modules
    const efi_module = b.addModule("efi_module", .{
        .code_model = .default,
        .root_source_file = b.path("src/boot/main.zig"),
        .target = efi_target,
        .optimize = efi_optimize,
    });

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

    const arch_module = b.addModule("arch_module", .{
        .root_source_file = b.path("src/arch/x86_64/mod.zig"),
    });

    const mm_module = b.addModule("mm_module", .{
        .root_source_file = b.path("src/mm/mod.zig"),
    });

    const shared_module = b.addModule("shared_module", .{
        .root_source_file = b.path("src/shared/mod.zig"),
    });

    // Imports
    efi_module.addImport("shared", shared_module);
    arch_module.addImport("mm", mm_module);
    arch_module.addImport("shared", shared_module);

    mm_module.addImport("shared", shared_module);
    mm_module.addImport("arch", arch_module);

    kernel_module.addImport("arch", arch_module);
    kernel_module.addImport("shared", shared_module);
    kernel_module.addImport("mm", mm_module);

    // Executables
    const efi_exe = b.addExecutable(.{
        .name = "bootx64.efi",
        .root_module = efi_module,
        .linkage = .static,
    });

    const kernel_exe = b.addExecutable(.{ .name = "ZincOS", .root_module = kernel_module });

    kernel_exe.setLinkerScript(b.path("src/kernel/linker.ld"));
    kernel_exe.root_module.addAssemblyFile(b.path(
        "src/arch/x86_64/asm/ap_trampoline.s",
    ));
    kernel_exe.root_module.addAssemblyFile(b.path(
        "src/arch/x86_64/asm/percpu_reload_cs.s",
    ));
    kernel_exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/asm/isr_stubs.s"));
    kernel_exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/asm/context_switch.s"));
    const out_dir_name = "img";
    const install_efi = b.addInstallFile(
        efi_exe.getEmittedBin(),
        b.fmt("{s}/efi/boot/{s}", .{ out_dir_name, efi_exe.name }),
    );

    install_efi.step.dependOn(&efi_exe.step);
    b.getInstallStep().dependOn(&install_efi.step);

    b.installArtifact(kernel_exe);
    const install_kernel = b.addInstallFile(kernel_exe.getEmittedBin(), b.fmt("{s}/efi/{s}", .{ out_dir_name, kernel_exe.name }));

    install_kernel.step.dependOn(&kernel_exe.step);
    b.getInstallStep().dependOn(&install_kernel.step);

    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-m",
        "1G",
        "-bios",
        "/usr/share/ovmf/x64/OVMF.4m.fd",
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        // "-nographic",
        "-serial",
        "mon:stdio",
        "-no-shutdown",
        "-smp",
        "20",
        "-cpu",
        "host,+invtsc",
        "--enable-kvm",
    };
    const qemu_cmd = b.addSystemCommand(&qemu_args);
    qemu_cmd.step.dependOn(b.getInstallStep());

    const run_qemu_cmd = b.step("run", "Run QMEU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);
}
