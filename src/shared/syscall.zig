//! Shared syscall numbers and errno encoding.
//!
//! Return convention:
//!     >= 0 : success value
//!     <  0 : -errno

pub const Number = enum(u64) {
    nop = 0,
    get_cpu_id = 1,
    sched_yield = 2,
    sys_read = 3,
    sys_write = 4,
    get_pid = 5,

    ipc_create_endpoint = 16,
    ipc_send = 17,
    ipc_receive = 18,
    ipc_call = 19,
    ipc_reply = 20,
};

pub const Errno = enum(i64) {
    BADF = 9,
    AGAIN = 11,
    NOMEM = 12,
    FAULT = 14,
    NODEV = 19,
    INVAL = 22,
    PIPE = 32,
    NOSYS = 38,
};

pub inline fn encodeErrno(code: Errno) u64 {
    const n: i64 = @intFromEnum(code);
    return @bitCast(-n);
}
