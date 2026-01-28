const builtin = @import("builtin");

/// Architecture-specific memory management implementation
pub const Impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/vmm.zig"),
    .aarch64 => @import("aarch64/vmm.zig"),
    else => @compileError("Unsupported architecture"),
};

/// The architecture-specific mapper context type
pub const MapperCtx = Impl.MapperCtx;
