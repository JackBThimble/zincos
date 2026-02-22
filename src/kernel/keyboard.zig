const arch = @import("arch");
const shared = @import("shared");
const log = shared.log;
const sched = @import("sched/core.zig");
const Task = @import("sched/task.zig").Task;

const SpinLock = sched.SpinLock;
const BUFFER_SIZE = 256;

var buf: [BUFFER_SIZE]u8 = undefined;
var head: usize = 0;
var tail: usize = 0;
var lock: SpinLock = .{};

/// Single blocked reader. Only one task can wait on stdin
/// at a time.
var waiting_task: ?*Task = null;

// =============================================================================
// Scan code set 1 -> ASCII (lowercase, no shift/ctrl/alt)
// =============================================================================
const scancode_table = blk: {
    var t = [_]u8{0} ** 128;
    t[0x01] = 27; // Escape
    t[0x02] = '1';
    t[0x03] = '2';
    t[0x04] = '3';
    t[0x05] = '4';
    t[0x06] = '5';
    t[0x07] = '6';
    t[0x08] = '7';
    t[0x09] = '8';
    t[0x0a] = '9';
    t[0x0b] = '0';
    t[0x0c] = '-';
    t[0x0d] = '=';
    t[0x0e] = 8; // Backspace
    t[0x0f] = '\t';
    t[0x10] = 'q';
    t[0x11] = 'w';
    t[0x12] = 'e';
    t[0x13] = 'r';
    t[0x14] = 't';
    t[0x15] = 'y';
    t[0x16] = 'u';
    t[0x17] = 'i';
    t[0x18] = 'o';
    t[0x19] = 'p';
    t[0x1a] = '[';
    t[0x1b] = ']';
    t[0x1c] = '\n';
    // 0x1d = Left Ctrl
    t[0x1e] = 'a';
    t[0x1f] = 's';
    t[0x20] = 'd';
    t[0x21] = 'f';
    t[0x22] = 'g';
    t[0x23] = 'h';
    t[0x24] = 'j';
    t[0x25] = 'k';
    t[0x26] = 'l';
    t[0x27] = ';';
    t[0x28] = '\'';
    t[0x29] = '`';
    // 0x2a = Left Shift
    t[0x2b] = '\\';
    t[0x2c] = 'z';
    t[0x2d] = 'x';
    t[0x2e] = 'c';
    t[0x2f] = 'v';
    t[0x30] = 'b';
    t[0x31] = 'n';
    t[0x32] = 'm';
    t[0x33] = ',';
    t[0x34] = '.';
    t[0x35] = '/';
    // 0x36 = Right Shift
    t[0x37] = '*';
    // 0x38 = Left Alt
    t[0x39] = ' ';
    break :blk t;
};

fn scancodeToAscii(scancode: u8) ?u8 {
    if (scancode & 0x80 != 0) return null; // key-up, ignore
    const ch = scancode_table[scancode];
    if (ch == 0) return null;
    return ch;
}

// =============================================================================
// ISR hook -- called from arch interrupt dispatch in interrupt context
// =============================================================================
pub fn handleIrq() void {
    const scancode = arch.serial.inb(0x60);
    const ch = scancodeToAscii(scancode) orelse return;

    lock.acquire();
    defer lock.release();

    const next_head = (head + 1) % BUFFER_SIZE;
    if (next_head == tail) return;

    buf[head] = ch;
    head = next_head;

    if (waiting_task) |t| {
        waiting_task = null;
        sched.wake(t);
    }
}

// =============================================================================
// Read interface
// =============================================================================

/// Read available bytes from the buffer. Caller must hold the lock.
fn tryReadLocked(dest: []u8) usize {
    var i: usize = 0;
    while (i < dest.len and tail != head) {
        dest[i] = buf[tail];
        tail = (tail + 1) % BUFFER_SIZE;
        i += 1;
    }
    return i;
}

/// Read from the keyboard, blocking if the buffer is empty
/// Called from syscall context where IRQs are disabled (SYSCALL clears IF).
///
/// Correctness: set task.state = .blocked while still holding the keyboard lock.
/// This prevents lost wakeups: if the ISR fires on another CPU after the lock is
/// released, wake() will see state == blocked and successfully enqueue the task.
/// IRQs are disabled on this CPU by SYSCALL, so no interrupt can fire between
/// the unlock and schedule().
pub fn readBlocking(dest: []u8, task: *Task) usize {
    while (true) {
        lock.acquire();
        const n = tryReadLocked(dest);
        if (n > 0) {
            lock.release();
            return n;
        }

        waiting_task = task;
        task.state = .blocked;
        lock.release();

        sched.schedule();
    }
}

// =============================================================================
// PS/2 controller initialization
// =============================================================================
pub fn init() void {
    // Flush any stale data from the PS/2 output buffer
    while (arch.serial.inb(0x64) & 0x01 != 0) {
        _ = arch.serial.inb(0x60);
    }

    waitInputClear();
    arch.serial.outb(0x64, 0x20);
    waitOutputReady();
    var config = arch.serial.inb(0x60);

    config |= (1 << 0) | (1 << 6);
    config &= ~@as(u8, 1 << 1);

    waitInputClear();
    arch.serial.outb(0x64, 0x60);
    waitInputClear();
    arch.serial.outb(0x60, config);

    log.info("PS/2 keyboard initialized", .{});
}

fn waitInputClear() void {
    var timeout: u32 = 10_000;
    while (timeout > 0) : (timeout -= 1) {
        if (arch.serial.inb(0x64) & 0x02 == 0) return;
        arch.serial.io_wait();
    }
}

fn waitOutputReady() void {
    var timeout: u32 = 10_000;
    while (timeout > 0) : (timeout -= 1) {
        if (arch.serial.inb(0x64) & 0x01 != 0) return;
        arch.serial.io_wait();
    }
}
