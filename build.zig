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
    const user_target = b.resolveTargetQuery(.{ .os_tag = .freestanding, .ofmt = .elf, .cpu_arch = .x86_64 });

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

    const initrd_packer_module = b.addModule("initrd_packer_module", .{
        .root_source_file = b.path("src/tools/pack_initrd.zig"),
        .target = b.graph.host,
    });

    const vfs_client_module = b.addModule("vfs_module", .{
        .root_source_file = b.path("src/userspace/vfs_client.zig"),
        .target = user_target,
        .optimize = kernel_optimize,
    });

    const ramfs_server_module = b.addModule("ramfs_server_module", .{
        .root_source_file = b.path("src/userspace/ramfs_server.zig"),
        .target = user_target,
        .optimize = kernel_optimize,
    });

    const shell_module = b.addModule("shell_module", .{
        .root_source_file = b.path("src/userspace/shell.zig"),
        .target = user_target,
        .optimize = kernel_optimize,
    });

    const syscall_fault_test_module = b.addModule("syscall_fault_test_module", .{
        .root_source_file = b.path("src/userspace/syscall_fault_tests.zig"),
        .target = user_target,
        .optimize = kernel_optimize,
    });

    const lib_module = b.addModule("lib_module", .{
        .root_source_file = b.path("src/userspace/lib/mod.zig"),
        .target = user_target,
        .optimize = kernel_optimize,
    });

    // Imports
    efi_module.addImport("shared", shared_module);
    arch_module.addImport("mm", mm_module);
    arch_module.addImport("shared", shared_module);
    shared_module.addImport("arch", arch_module);
    lib_module.addImport("shared", shared_module);
    syscall_fault_test_module.addImport("lib", lib_module);

    mm_module.addImport("shared", shared_module);
    mm_module.addImport("arch", arch_module);

    kernel_module.addImport("arch", arch_module);
    kernel_module.addImport("shared", shared_module);
    kernel_module.addImport("mm", mm_module);

    initrd_packer_module.addImport("shared", shared_module);
    vfs_client_module.addImport("lib", lib_module);
    ramfs_server_module.addImport("lib", lib_module);
    shell_module.addImport("lib", lib_module);

    // Executables
    const efi_exe = b.addExecutable(.{
        .name = "bootx64.efi",
        .root_module = efi_module,
        .linkage = .static,
    });

    const kernel_exe = b.addExecutable(.{
        .name = "ZincOS",
        .root_module = kernel_module,
    });

    const initrd_packer_exe = b.addExecutable(.{
        .name = "initrd_packer",
        .root_module = initrd_packer_module,
    });

    const ramfs_server_exe = b.addExecutable(.{
        .name = "ramfs_server",
        .root_module = ramfs_server_module,
    });

    const vfs_client_exe = b.addExecutable(.{
        .name = "vfs_client",
        .root_module = vfs_client_module,
    });

    const shell_exe = b.addExecutable(.{
        .name = "shell",
        .root_module = shell_module,
    });

    const syscall_fault_test_exe = b.addExecutable(.{
        .name = "syscall_test",
        .root_module = syscall_fault_test_module,
    });

    kernel_exe.use_llvm = true;
    kernel_exe.use_lld = true;
    kernel_exe.setLinkerScript(
        b.path("src/kernel/linker.ld"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/ap_trampoline.s"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/percpu_reload_cs.s"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/isr_stubs.s"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/context_switch.s"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/syscall_entry.s"),
    );
    kernel_exe.root_module.addAssemblyFile(
        b.path("src/arch/x86_64/asm/user_entry.s"),
    );

    const out_dir_name = "img";
    const install_efi = b.addInstallFile(
        efi_exe.getEmittedBin(),
        b.fmt("{s}/efi/boot/{s}", .{ out_dir_name, efi_exe.name }),
    );

    // -------------------------------------------------------------------------
    // Pack InitRD -> install into FAT image
    // -------------------------------------------------------------------------
    const pack_initrd = b.addRunArtifact(initrd_packer_exe);
    pack_initrd.setCwd(b.path("."));

    const initrd_img = pack_initrd.addOutputFileArg("initrd.img");

    pack_initrd.addArg("--init");
    pack_initrd.addFileArg(ramfs_server_exe.getEmittedBin());
    pack_initrd.addArg("--exec");
    pack_initrd.addFileArg(vfs_client_exe.getEmittedBin());
    pack_initrd.addArg("--exec");
    pack_initrd.addFileArg(shell_exe.getEmittedBin());
    pack_initrd.addArg("--exec");
    pack_initrd.addFileArg(syscall_fault_test_exe.getEmittedBin());
    pack_initrd.step.dependOn(&ramfs_server_exe.step);
    pack_initrd.step.dependOn(&vfs_client_exe.step);
    pack_initrd.step.dependOn(&shell_exe.step);

    const install_initrd = b.addInstallFile(
        initrd_img,
        b.fmt("{s}/efi/{s}", .{ out_dir_name, "initrd.img" }),
    );

    install_initrd.step.dependOn(&pack_initrd.step);
    b.getInstallStep().dependOn(&install_initrd.step);

    install_efi.step.dependOn(&efi_exe.step);
    b.getInstallStep().dependOn(&install_efi.step);

    b.installArtifact(kernel_exe);
    b.installArtifact(ramfs_server_exe);
    b.installArtifact(vfs_client_exe);
    b.installArtifact(shell_exe);
    b.installArtifact(syscall_fault_test_exe);
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

    const run_qemu_cmd = b.step("run", "Run QEMU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);
}
