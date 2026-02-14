# ZincOS

> A hobby, hybrid microkernel written in Zig.
> Because writing a kernel seemed like a good idea.

--- 

## What is this???

ZincOS is my attempt at building a 64-bit operating system from scratch using Zig.

It boots via UEFI, runs in long mode, and is slowly growing into something resembling a kernel.

Right now it's mostly:
- Memory mapping experiments
- SMP bring-up chaos
- ACPI parsing
- Scheduler prototypes
- Syscall wiring
- Me learning more about how CPUs actually work

This is not production software.
This is not stable
This is not even remotely finished.

It's just for fun.

--- 

## Why?

Because I wanted to understand:

- How paging really works
- What it takes to bring up multiple CPUs
- How interrupts are wired
- How kernels structure per-CPU data
- What TLB shootdowns actually involve
- And how much pain ACPI parsing contains

---

## Current Status

Things that work (sometimes):

- UEFI boot
- Physical memory map ingestion
- Higher-half kernel mapping
- PML4-based virtual memory
- Address space switching
- Basic scheduler
- IPC experiments
- Syscall dispatcher (needs love)
- Early ACPI table parsing (for CPU enumeration)
- IDT/GDT setup

Things that are in the works:

- ELF loader
- User space model
- SMP final wiring
- Per-CPU permanent structures
- TLB shootdown logic

Things that absolutely do not exist yet:
- Filesystem
- Drivers
- Graphics
- Networking
- Anything resembling a userspace

---

## Design Goals (loosely defined)

- Keep architecture understandable
- Avoid abstraction hell
- Prefer explicit memory control
- Make SMP first-class
- Avoid turning into a Linux clone
- Have fun

---

## Build

You'll need:
- Zig (0.16-dev)
- QEMU or a UEFI machine
- Patience

```bash
zig build
```

---

## Run in QEMU


```bash
zig build run
```

---

## Project Structure

This has been a real point of contention. It has changed several times and will probably change 20 more times.

My goal is to have all architecture specific code in an `arch` module that will implement a common API for other modules to consume.

```bash
src/
    |-- arch/
    |-- boot/
    |-- kernel/
    |-- mm/
    |-- shared/
```

- `src/arch`
This module contains ALL architecture specific code, which is for the time being, x86_64 only. My plan is for all modules to implement a common API, and the module implementation will be selected at build time via Zig's `builtin.cpu.arch`.
- `src/boot`
The UEFI loader application which loads the kernel ELF, creates a BootInfo struct, and passes it to the kernel entry point.
- `src/kernel` 
The core logic for the kernel.
- `src/mm`
Memory management interfaces. Currently implements a PMM, VMM, address space, and kernel heap interface.
- `src/shared` 
This is for common types and data structures used by all modules.

---

## Status

Very early.
Very experimental.
Very educational.

If you're looking for stability, use Linux.

If you're looking for someone learning kernel internals the hard way, welcome.
