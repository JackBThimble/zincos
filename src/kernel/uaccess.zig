const std = @import("std");
const mm = @import("mm");
const Task = @import("sched/task.zig").Task;

pub const USER_ADDR_MAX: u64 = mm.address_space.USER_ADDR_MAX;

fn validateUserRange(raw: u64, len: usize) bool {
    if (raw == 0) return len == 0;
    if (raw > USER_ADDR_MAX) return false;
    if (len == 0) return true;

    const last = std.math.add(u64, raw, @as(u64, @intCast(len - 1))) catch return false;
    return last <= USER_ADDR_MAX;
}

pub fn validateUserBuffer(task: *Task, raw: u64, len: usize, write: bool) bool {
    if (!validateUserRange(raw, len)) return false;
    if (len == 0) return true;

    const as = task.addr_space orelse return false;
    return as.isUserRangeAccessible(raw, len, write);
}

pub fn copyFromUser(task: *Task, dst: []u8, src_user_addr: u64) bool {
    if (!validateUserBuffer(task, src_user_addr, dst.len, false)) return false;
    if (dst.len == 0) return true;

    const src: [*]const u8 = @ptrFromInt(src_user_addr);
    @memcpy(dst, src[0..dst.len]);
    return true;
}

pub fn copyToUser(task: *Task, dst_user_addr: u64, src: []const u8) bool {
    if (!validateUserBuffer(task, dst_user_addr, src.len, true)) return false;
    if (src.len == 0) return true;

    const dst: [*]u8 = @ptrFromInt(dst_user_addr);
    @memcpy(dst[0..src.len], src);
    return true;
}

pub fn copyFromUserValue(comptime T: type, task: *Task, src_user_addr: u64, out: *T) bool {
    return copyFromUser(task, std.mem.asBytes(out), src_user_addr);
}

pub fn copyToUserValue(comptime T: type, task: *Task, dst_user_addr: u64, value: *const T) bool {
    return copyToUser(task, dst_user_addr, std.mem.asBytes(value));
}
