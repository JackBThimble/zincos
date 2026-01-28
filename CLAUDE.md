# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZincOS is a custom x86_64 OS hybrid microkernel written in Zig with NASM assembly for low-level CPU operations. It boots via UEFI and runs a freestanding kernel with its own memory management.

**Hybrid MicroKernel**
This is intended to be a minimal-ish hybrid microkernel design. Exceptions will be made for performance critical
paths such as graphics. 

## Build Commands

```bash
zig build          # Build bootloader and kernel
zig build run      # Build and run in QEMU (KVM, 1GB RAM, UEFI)
zig build debug    # Build and launch QEMU with GDB stub on port 1234
```

For debugging, attach with: `gdb -ex 'target remote localhost:1234'`

## Architecture

### Target
This OS will target modern hardware only, no legacy support for 32-bit x86.
X86_64 will be the primary target for MVP.
ArmV8 Support will be added next.

### Boot Sequence
1. **UEFI Bootloader** (`src/boot/main.zig`): Initializes graphics, loads kernel ELF from `\efi\ZincOS`, builds page tables with HHDM, exits boot services, jumps to kernel
2. **Kernel Entry** (`src/kernel/main.zig`): Validates boot magic, initializes GDT/IDT, sets up PMM/VMM/heap, runs allocator stress tests

### X86_64 (`src/arch/x86_64/`)
**Interrupts**
- `interrupts/idt.zig` - Sets up interrupt handlers
- `interrupts/isr.asm` - ISR/IRQ stubs and handlers
- `interrupts/page_fault.zig` - Extra functionality to output more information on page faults for memory debugging.
- `apic.zig` - Advanced Programmable Interrupt Controller initializations for serial output
**GDT/TSS**
- `gdt.zig` - Sets up GDT with TSS 
- `gdt_load.asm` - Raw nasm assembly workaround due to zig compiler failure to emit correct lretq instruction from inline asm.
**CPUID**
- `cpuid.zig` - Feature detection
    - TODO: Add feature detection
**TSC**
- `tsc.zig` - Support for Time Stamp Counter for tickless scheduler
    - TODO: Initialize TSC and one shot timers
**MSR**
- `msr.zig` - Read/write model-specific registers
**SERIAL**
- `serial.zig` - Serial I/O. Includes functions for printing to serial console, including format specifiers with printf()/printfln()
**SYSCALL**
- `syscall.zig` - syscall/sysret, syscall definitions. 
    - TODO: Define syscalls for scheduling, memory allocation, file i/o, IPC, etc.
**SMP**
- TODO: SMP Bring up, AP initialization
- TODO: Per-cpu*

### Aarch64 (`src/arch/aarch64`)
- TODO: Add arm support

### Memory Layout (x64)
- **Kernel virtual base**: `0xFFFFFFFF80000000` (higher-half)
- **HHDM base**: `0xFFFF800000000000` (direct map of physical memory)
- **Heap region**: `0xFFFFC00000000000+`
- **Kernel physical base**: `0x100000`

### Key Components

**Memory Management** (`src/mm/`):
- `pmm.zig` - Bitmap-based physical frame allocator (4KB pages)
- `vmm.zig` - Arch-agnostic `MapFlags` and `Mapper` interface (vtable). No arch-specific code here.
- `kheap.zig` - Kernel heap allocator using the `Mapper` interface
- `debug.zig` - Stress test for kernel heap allocator

**Memory Abstraction Pattern:**
The mm module is completely architecture-agnostic. It defines:
- `vmm.MapFlags` - Arch-agnostic flags (writable, executable, user, device, etc.)
- `vmm.Mapper` - Interface struct with vtable for map4k, unmap4k, allocFrame, freeFrame

The arch module implements the interface:
- `arch.mm.MapperCtx` - Arch-specific context (e.g., x86_64 has hhdm_base, frame allocator)
- `ctx.mapper()` - Returns a `vmm.Mapper` that mm can use without knowing arch details
- PTE bits and translation are internal to the arch implementation

**Common** (`src/common`) : Functions as a HAL layer that all modules can import
- `log.zig` - Level-filtering logger (currently supports serial console only)
- `cpu.zig` - Per-cpu abstraction
- `boot_info.zig` - Not HAL, but needs to be in central location. Defines all data structures and information passed from the bootloader to the kernel

**Architecture** (`src/arch/`):
- `arch.zig` - Interface for arch-agnostic kernel to consume
- `serial.zig` - Interface for logger to print to serial console
- `mem.zig` - Exports arch-specific `MapperCtx` type (selects x86_64 or aarch64 implementation)
- `x86_64/vmm.zig` - x86_64 page table implementation, translates `mm.vmm.MapFlags` to PTE bits
- `aarch64/vmm.zig` - AArch64 page table implementation (stub)

**Bootloader** (`src/boot/`):
- `loader.zig` - ELF parser for kernel loading
- `paging.zig` - Page table construction with HHDM
- `memory.zig` - UEFI memory map processing

**Scheduling**
- TODO: Add tickless, per-cpu scheduling.

**IPC**
- TODO: Add IPC

**Graphics**
- TODO: Add graphics support at kernel level for fast paths...

### Boot Contract

The bootloader passes `BootInfo` (defined in `src/common.zig`) to the kernel:
- Magic: `0xB007_1AF0_DEAD_BEEF`
- Framebuffer info, memory map, kernel location, RSDP address, HHDM base

### Build Targets
- Bootloader: `x86_64-uefi-msvc` → `bootx64.efi`
- Kernel: `x86_64-freestanding` with kernel code model, no red-zone, no PIC

Assembly files (`*.asm`) are assembled with NASM and linked into the kernel.

## Design Considerations
**Namespaces/Modules**
- `src/boot` - Contains all UEFI application code
- `src/kernel` - Namespace intended for architecture agnostic component implementation
- `src/arch` - Module for architecture specific component initialization/implementation. This is the ONLY place with `builtin.cpu.arch` switches.
- `src/mm` - Module for memory management. Completely arch-agnostic; uses interfaces provided by arch.
- `src/common` - HAL layer for serial, cpu, logging, and boot info definitions

**Architecture Abstraction Rule:**
Only `src/arch/` may contain architecture detection logic (`builtin.cpu.arch`). Other modules (mm, kernel) consume interfaces without knowing the underlying architecture.

