const log = @import("shared").log;
const KHeap = @import("kheap.zig").KHeap;

// Simple xorshift64 PRNG for stress testing
var rng_state: u64 = 0xdeadbeefcafebabe;

fn rand() u64 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x;
    return x;
}

fn randRange(max: usize) usize {
    return @intCast(rand() % max);
}

const MAX_BLOCKS = 1024;
var blocks: [MAX_BLOCKS]Block = undefined;
var block_count: usize = 0;

const Block = struct {
    ptr: ?[*]u8,
    size: usize,
    alignment: usize,
    tag: u8,
};

pub fn heap_stress_test(kheap: *KHeap) void {
    log.debug("Starting heap stress test...", .{});

    for (0..MAX_BLOCKS) |i| {
        blocks[i] = .{ .ptr = null, .size = 0, .alignment = 0, .tag = 0 };
    }

    const ITER = 200_000;

    for (0..ITER) |i| {
        const action = randRange(100);

        if ((action < 60 or block_count == 0) and block_count < MAX_BLOCKS) {
            const size = (randRange(4096) + 1);
            const alignment = @as(usize, 1) << @intCast(randRange(6));
            const p = kheap.kmalloc(size, alignment) orelse continue;
            const tag: u8 = @intCast(rand() & 0xff);

            if ((@intFromPtr(p) & (alignment - 1)) != 0) {
                @panic("alignment is fucked");
            }

            for (0..size) |j| p[j] = tag;

            blocks[block_count] = .{
                .ptr = p,
                .size = size,
                .alignment = alignment,
                .tag = tag,
            };
            block_count += 1;
        } else if (action < 85) {
            const idx = randRange(block_count);
            const b = blocks[idx];
            kheap.kfree(b.ptr.?);

            blocks[idx] = blocks[block_count - 1];
            block_count -= 1;
        } else {
            const idx = randRange(block_count);
            var b = &blocks[idx];

            const new_size = randRange(4096) + 1;
            const newp = kheap.krealloc(b.ptr.?, new_size, b.alignment) orelse continue;

            const min = if (b.size < new_size) b.size else new_size;

            for (0..min) |j| {
                if (newp[j] != b.tag) {
                    log.err("CORRUPTION: idx={} j={} expected={} got={}", .{ idx, j, b.tag, newp[j] });
                    @panic("realloc failed\n");
                }
            }

            // If we grew the allocation, fill the extended portion with the tag
            // so future reallocs can verify the entire allocation
            if (new_size > b.size) {
                for (b.size..new_size) |j| {
                    newp[j] = b.tag;
                }
            }

            b.ptr = newp;
            b.size = new_size;
        }

        if (i % 10000 == 0) {
            log.debug("Iteration: {}", .{i});
        }
    }
    log.debug("Heap stress test PASSED\n", .{});
}
