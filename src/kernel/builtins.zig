// Compiler builtins required for freestanding Zig
// These are normally provided by compiler-rt or libc

export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        for (0..len) |i| {
            dest[i] = src[i];
        }
    } else {
        var i = len;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

export fn memset(dest: [*]u8, val: u8, len: usize) [*]u8 {
    for (0..len) |i| {
        dest[i] = val;
    }
    return dest;
}

export fn memcmp(s1: [*]const u8, s2: [*]const u8, len: usize) c_int {
    for (0..len) |i| {
        if (s1[i] != s2[i]) {
            return @as(c_int, s1[i]) - @as(c_int, s2[i]);
        }
    }
    return 0;
}
