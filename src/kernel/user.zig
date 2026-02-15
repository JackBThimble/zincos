const std = @import("std");
const shared = @import("shared");
const log = shared.log;
const process = @import("process/mod.zig");
const task = @import("sched/task.zig");

const EHDR_SIZE: usize = @sizeOf(std.elf.Elf64.Ehdr);
const PHDR_SIZE: usize = @sizeOf(std.elf.Elf64.Phdr);
const USER_DEMO_BASE_VA: u64 = 0x0000_0080_0040_0000;
const USER_DEMO_SEGMENT_OFFSET: usize = 0x1000;

const demo_msg = "user-demo: pid/sys_write/sys_read/ipc ok\n";

const demo_code_template = [_]u8{
    0xb8, 0x05, 0x00, 0x00, 0x00, // mov eax, 5 (get_pid)
    0x0f, 0x05, // syscall
    0xb8, 0x04, 0x00, 0x00, 0x00, // mov eax, 4 (sys_write)
    0xbf, 0x01, 0x00, 0x00, 0x00, // mov edi, 1 (stdout)
    0x48, 0xbe, 0, 0, 0, 0, 0, 0, 0, 0, // movabs rsi, msg_addr
    0xba, @as(u8, demo_msg.len), 0x00, 0x00, 0x00, // mov edx, msg_len
    0x0f, 0x05, // syscall
    0xb8, 0x03, 0x00, 0x00, 0x00, // mov eax, 3 (sys_read)
    0x31, 0xff, // xor edi, edi (stdin)
    0x48, 0xbe, 0, 0, 0, 0, 0, 0, 0, 0, // movabs rsi, buf_addr
    0xba, 0x01, 0x00, 0x00, 0x00, // mov edx, 1
    0x0f, 0x05, // syscall
    0xb8, 0x10, 0x00, 0x00, 0x00, // mov eax, 16 (ipc_create_endpoint)
    0x0f, 0x05, // syscall
    0xb8, 0x02, 0x00, 0x00, 0x00, // mov eax, 2 (sched_yield)
    0x0f, 0x05, // syscall
    0xeb, 0xfe, // spin
};

const USER_DEMO_PAYLOAD_SIZE = demo_code_template.len + demo_msg.len + 1;
const USER_DEMO_ELF_SIZE = USER_DEMO_SEGMENT_OFFSET + USER_DEMO_PAYLOAD_SIZE;

fn putU16Le(dst: []u8, value: u16) void {
    std.mem.writeInt(u16, dst[0..2], value, .little);
}

fn putU32Le(dst: []u8, value: u32) void {
    std.mem.writeInt(u32, dst[0..4], value, .little);
}

fn putU64Le(dst: []u8, value: u64) void {
    std.mem.writeInt(u64, dst[0..8], value, .little);
}

fn buildDemoElfImage() [USER_DEMO_ELF_SIZE]u8 {
    var image: [USER_DEMO_ELF_SIZE]u8 = [_]u8{0} ** USER_DEMO_ELF_SIZE;

    // Elf64h header
    image[0] = 0x7f;
    image[1] = 'E';
    image[2] = 'L';
    image[3] = 'F';
    image[4] = 2; // 64 bit
    image[5] = 1; // little endian
    image[6] = 1; // ELF version

    putU16Le(image[16..18], 2); // ET_EXEC
    putU16Le(image[18..20], 0x3e); // EM_X86_64
    putU32Le(image[20..24], 1); // version
    putU64Le(image[24..32], USER_DEMO_BASE_VA); // e_entry
    putU64Le(image[32..40], EHDR_SIZE); // e_phoff
    putU16Le(image[52..54], EHDR_SIZE); // e_ehsize
    putU16Le(image[54..56], PHDR_SIZE); // e_phentsize
    putU16Le(image[56..58], 1); // e_phnum

    // Program header (PT_LOAD)
    const ph = EHDR_SIZE;
    putU32Le(image[ph + 0 .. ph + 4], 1); // PT_LOAD
    putU32Le(image[ph + 4 .. ph + 8], 0x7); // R|W|X
    putU64Le(image[ph + 8 .. ph + 16], USER_DEMO_SEGMENT_OFFSET);
    putU64Le(image[ph + 16 .. ph + 24], USER_DEMO_BASE_VA);
    putU64Le(image[ph + 24 .. ph + 32], USER_DEMO_BASE_VA);
    putU64Le(image[ph + 32 .. ph + 40], USER_DEMO_PAYLOAD_SIZE);
    putU64Le(image[ph + 40 .. ph + 48], USER_DEMO_PAYLOAD_SIZE);
    putU64Le(image[ph + 48 .. ph + 56], 0x1000);

    const payload = image[USER_DEMO_SEGMENT_OFFSET..][0..USER_DEMO_PAYLOAD_SIZE];
    @memcpy(payload[0..demo_code_template.len], demo_code_template[0..]);

    const msg_addr = USER_DEMO_BASE_VA + demo_code_template.len;
    const buf_addr = msg_addr + demo_msg.len;

    putU64Le(payload[19..27], msg_addr);
    putU64Le(payload[43..51], buf_addr);

    @memcpy(payload[demo_code_template.len .. demo_code_template.len + demo_msg.len], demo_msg);
    payload[payload.len - 1] = 0;

    return image;
}

pub fn spawnDemoUserProcess(allocator: std.mem.Allocator) !void {
    var image = buildDemoElfImage();

    const proc = try process.createFromElf(
        allocator,
        "user-elf-demo",
        image[0..],
        task.Priority.NORMAL_DEFAULT,
    );

    log.info("User process demo wired: pid={} name='{s}'", .{
        proc.pid,
        proc.nameSlice(),
    });
}
