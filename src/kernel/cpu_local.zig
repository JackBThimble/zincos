const common = @import("common");
const arch = @import("arch");

var cpus: [common.MAX_CPUS]common.CpuLocal = [_]common.CpuLocal{.{}} ** common.MAX_CPUS;
var cpu_online_count: usize = 0;

inline fn atomicInc(ptr: *usize) usize {
    // returns previous value
    return @atomicRmw(usize, ptr, .Add, 1, .seq_cst);
}

// BSP Init
pub fn init_bsp(bsp_stack_top: usize) void {
    const id = arch.cpu_id();
    const data = arch.cpu_arch_data();

    cpus[id] = .{
        .present = true,
        .id = id,
        .stack_top = bsp_stack_top,
        .arch = data,
    };

    _ = atomicInc(&cpu_online_count);

    arch.smp_set_ap_entry(ap_entry);
}

pub fn ap_entry(stack_top: usize) callconv(.c) noreturn {
    const id = register_ap(stack_top);

    const serial = @import("arch").serial;
    serial.printfln("CPU {d} online", .{id});

    arch.halt();
}

pub fn register_ap(stack_top: usize) usize {
    const id = arch.cpu_id();

    if (!cpus[id].present) {
        cpus[id].present = true;
        cpus[id].id = id;
        cpus[id].stack_top = stack_top;
        cpus[id].arch = arch.cpu_arch_data();
        _ = atomicInc(&cpu_online_count);
    } else {
        cpus[id].stack_top = stack_top;
    }

    return id;
}

pub fn cpu_id() usize {
    return arch.cpu_id();
}

pub fn cpu_local() *common.CpuLocal {
    return &cpus[cpu_id()];
}

pub fn cpu_ptr(id: usize) *common.CpuLocal {
    return &cpus[id];
}

pub fn total_online() usize {
    return @atomicLoad(usize, &cpu_online_count, .seq_cst);
}
