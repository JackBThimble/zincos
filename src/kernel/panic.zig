const std = @import("std");
const arch = @import("arch");
const serial = arch.serial;
const dumpCpuState = arch.dumpCpuState;
const halt = arch.halt_catch_fire;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    serial.println("\n============================================");
    serial.println("                 KERNEL PANIC");
    serial.println("============================================");
    serial.printfln("Message: {s}", .{msg});

    if (ret_addr) |addr| {
        serial.printfln("Return address: 0x{x}", .{addr});
    }

    if (error_return_trace) |trace| {
        serial.println("\nStack trace:");
        dumpStackTrace(trace);
    }

    dumpCpuState();

    serial.println("\nSystem halted.");
    halt();
}

fn dumpStackTrace(trace: *std.builtin.StackTrace) void {
    const n: usize = @min(trace.index, trace.instruction_addresses.len);

    for (trace.instruction_addresses[0..n], 0..) |addr, i| {
        if (addr == 0) break;
        serial.printfln("    #{d}: 0x{x}", .{ i, addr });
    }

    if (trace.index > trace.instruction_addresses.len) {
        serial.printfln("    (trace truncated: index={d} cap={d}", .{
            trace.index, trace.instruction_addresses.len,
        });
    }
}
