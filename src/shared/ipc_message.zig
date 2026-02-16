//! Shared IPC message ABI.
//!
//! This layout is used across the syscall boundary and by all IPC peers.

pub const MAX_DATA_WORDS = 6;

pub const Flag = struct {
    pub const CALL: u64 = 1 << 36;
};

pub const Message = struct {
    tag: u64 = 0,
    data: [MAX_DATA_WORDS]u64 = [_]u64{0} ** MAX_DATA_WORDS,

    pub fn init(message_label: u32, len: u4) Message {
        return .{
            .tag = @as(u64, message_label) | (@as(u64, len) << 32),
        };
    }

    pub fn label(self: *const Message) u32 {
        return @truncate(self.tag);
    }

    pub fn length(self: *const Message) u4 {
        return @truncate(self.tag >> 32);
    }

    pub fn flags(self: *const Message) u28 {
        return @truncate(self.tag >> 36);
    }

    pub fn setFlag(self: *Message, flag: u64) void {
        self.tag |= flag;
    }

    pub fn clearFlag(self: *Message, flag: u64) void {
        self.tag &= ~flag;
    }

    pub fn hasFlag(self: *const Message, flag: u64) bool {
        return (self.tag & flag) != 0;
    }

    pub fn set(self: *Message, idx: usize, val: u64) void {
        self.data[idx] = val;
    }

    pub fn get(self: *const Message, idx: usize) u64 {
        return self.data[idx];
    }
};
