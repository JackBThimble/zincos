pub inline fn rdtsc() u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;
    asm volatile (
        \\rdtsc
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}
