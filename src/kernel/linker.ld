/* ============================================================================
 * Kernel Linker Script for x86_64
 * ============================================================================
 * 
 * This linker script supports both identity-mapped and higher-half kernels.
 * 
 * Memory Layout:
 *   Physical: 0x100000 (1MB) - Loaded here by bootloader
 *   Virtual:  0xFFFFFFFF80000000 (-2GB) - Higher-half mapping (optional)
 * 
 * To use identity mapping only, set KERNEL_VIRT_BASE = KERNEL_PHYS_BASE
 * 
 * Section Layout:
 *   .text     - Executable code (r-x)
 *   .rodata   - Read-only data, including interrupt tables (r--)
 *   .data     - Initialized read-write data (rw-)
 *   .bss      - Zero-initialized data (rw-)
 * 
 * Exported Symbols (use these in your kernel):
 *   __kernel_start      - Start of kernel in memory
 *   __kernel_end        - End of kernel (for memory allocator)
 *   __text_start/end    - Code section bounds
 *   __rodata_start/end  - Read-only data bounds
 *   __data_start/end    - Initialized data bounds  
 *   __bss_start/end     - BSS bounds (zero these at startup if needed)
 *   __kernel_phys_base  - Physical load address
 *   __kernel_virt_base  - Virtual base address
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

/* ============================================================================
 * Configuration
 * ============================================================================ */

/* Physical address where bootloader loads us (1MB mark, above legacy BIOS area) */
KERNEL_PHYS_BASE = 0x100000;

/* Virtual address for higher-half kernel
 * This is the -2GB mark, a common choice that leaves plenty of user space
 * For identity mapping, set this equal to KERNEL_PHYS_BASE */
KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;

/* Offset to convert virtual addresses to physical */
KERNEL_OFFSET = KERNEL_VIRT_BASE - KERNEL_PHYS_BASE;

/* ============================================================================
 * Program Headers
 * ============================================================================ */

PHDRS
{
    /* Separate segments with proper permissions for page table setup */
    text    PT_LOAD FLAGS(5);  /* PF_R | PF_X = r-x */
    rodata  PT_LOAD FLAGS(4);  /* PF_R       = r-- */
    data    PT_LOAD FLAGS(6);  /* PF_R | PF_W = rw- */
}

/* ============================================================================
 * Sections
 * ============================================================================ */

SECTIONS
{
    /* Start at virtual address, but load at physical address */
    . = KERNEL_VIRT_BASE;
    
    __kernel_start = .;
    __kernel_phys_base = KERNEL_PHYS_BASE;
    __kernel_virt_base = KERNEL_VIRT_BASE;

    /* ========================================================================
     * .text - Executable Code
     * ======================================================================== */
    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_OFFSET)
    {
        __text_start = .;
        
        /* Entry point should be first */
        *(.text._start)
        *(.text.boot)
        
        /* Main code */
        *(.text .text.*)
        
        /* Interrupt handlers - keep together for cache locality */
        *(.text.isr*)
        *(.text.irq*)
        
        __text_end = .;
    } :text

    /* ========================================================================
     * .rodata - Read-Only Data
     * ======================================================================== */
    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_OFFSET)
    {
        __rodata_start = .;
        
        *(.rodata .rodata.*)
        
        /* String literals */
        *(.rodata.str*)
        
        /* GDT, IDT descriptors if defined in rodata */
        *(.rodata.gdt*)
        *(.rodata.idt*)
        
        __rodata_end = .;
    } :rodata

    /* ========================================================================
     * .data - Initialized Read-Write Data
     * ======================================================================== */
    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_OFFSET)
    {
        __data_start = .;
        
        *(.data .data.*)
        
        /* Global constructors (C++ or Zig comptime) */
        __init_array_start = .;
        KEEP(*(.init_array))
        KEEP(*(.init_array.*))
        __init_array_end = .;
        
        /* Global destructors */
        __fini_array_start = .;
        KEEP(*(.fini_array))
        KEEP(*(.fini_array.*))
        __fini_array_end = .;
        
        __data_end = .;
    } :data

    /* ========================================================================
     * .bss - Uninitialized Data (zeroed by convention)
     * ======================================================================== */
    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_OFFSET)
    {
        __bss_start = .;
        
        *(.bss .bss.*)
        *(COMMON)
        
        /* Reserve space for initial kernel stack if not allocated elsewhere
         * Uncomment and adjust size as needed:
         *
         * . = ALIGN(16);
         * __stack_bottom = .;
         * . += 64K;
         * __stack_top = .;
         */
        
        __bss_end = .;
    } :data

    /* ========================================================================
     * End Markers
     * ======================================================================== */
    
    . = ALIGN(4K);
    __kernel_end = .;
    
    /* Physical end address (useful for bootloader handoff) */
    __kernel_phys_end = __kernel_end - KERNEL_OFFSET;
    
    /* Kernel size in bytes */
    __kernel_size = __kernel_end - __kernel_start;

    /* ========================================================================
     * Discarded Sections
     * ======================================================================== */
    /DISCARD/ :
    {
        /* Debug info - remove for release builds, keep for debugging */
        /* *(.debug*) */
        
        /* Comments and notes */
        *(.comment)
        *(.note .note.*)
        
        /* Exception handling frames - not needed for freestanding */
        *(.eh_frame .eh_frame_hdr)
        *(.gcc_except_table)
        
        /* Dynamic linking - not used in kernel */
        *(.gnu.hash)
        *(.dynsym)
        *(.dynstr)
        *(.dynamic)
        *(.interp)
        *(.plt .plt.*)
        *(.got .got.*)
        
        /* LLVM/Clang specific */
        *(.llvm*)
    }
}

/* ============================================================================
 * Assertions
 * ============================================================================ */

/* Ensure kernel doesn't exceed reasonable size (16MB) */
ASSERT(__kernel_size < 16M, "Kernel too large! Check for bloat.")

/* Ensure proper alignment */
ASSERT(__text_start % 4K == 0, ".text not page-aligned")
ASSERT(__rodata_start % 4K == 0, ".rodata not page-aligned")
ASSERT(__data_start % 4K == 0, ".data not page-aligned")
ASSERT(__bss_start % 4K == 0, ".bss not page-aligned")


