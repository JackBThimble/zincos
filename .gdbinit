target remote localhost:1234

file zig-out/bin/ZincOS

set architecture i386:x86-64:intel

break _start

display/i $pc
