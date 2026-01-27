const std = @import("std");
const arch = @import("arch");

const SpinLock = struct {
    locked: u8 = 0,

    pub fn lock(self: *SpinLock) void {
        while (@atomicRmw(u8, &self.locked, .Xchg, 1, .seq_cst) == 1) {
            if (@import("builtin").cpu.arch == .x86_64) {
                arch.pause();
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        @atomicStore(u8, &self.locked, 0, .seq_cst);
    }
};
