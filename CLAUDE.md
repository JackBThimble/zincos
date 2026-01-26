# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZincOS is a custom x86_64 OS hybrid microkernel written in Zig with NASM assembly for low-level CPU operations. It boots via UEFI and runs a freestanding kernel with its own memory management.

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

### X86_64 
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

### Memory Layout
- **Kernel virtual base**: `0xFFFFFFFF80000000` (higher-half)
- **HHDM base**: `0xFFFF800000000000` (direct map of physical memory)
- **Heap region**: `0xFFFFC00000000000+`
- **Kernel physical base**: `0x100000`

### Key Components

**Memory Management** (`src/kernel/mm/`):
- `pmm.zig` - Bitmap-based physical frame allocator (4KB pages)
- `vmm.zig` - 4-level page table walker with map/unmap operations
- `kalloc.zig` - Free-list allocator with coalescing and splitting
- `kheap.zig` - Interim redesign of kalloc.zig free-list allocator for a basic kernel allocator
- `heap.zig` - Linear page allocator backing kalloc

**Architecture** (`src/arch/x86_64/`):
- `gdt.zig` + `gdt_load.asm` - GDT with TSS and interrupt stacks
- `interrupts/idt.zig` + `isr.asm` - IDT with 256 interrupt handlers
- `serial.zig` - COM1 debug output (38400 baud)

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
- `src/arch` - Module for architecture specific component initialization/implementation

**Hybrid MicroKernel**
This is intended to be a minimal-ish hybrid microkernel design. Exceptions will be made for performance critical
paths such as graphics. 

