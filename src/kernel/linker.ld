/* Kernel linker script for higher-half x86_64 */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;
KERNEL_PHYS_BASE = 0x100000;

SECTIONS
{
    . = KERNEL_VIRT_BASE;

    __kernel_start = .;
    __kernel_virt_base = KERNEL_VIRT_BASE;
    __kernel_phys_base = KERNEL_PHYS_BASE;

    .text ALIGN(4K) : AT(KERNEL_PHYS_BASE)
    {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    }

    .rodata ALIGN(4K) : AT(KERNEL_PHYS_BASE + (ADDR(.rodata) - KERNEL_VIRT_BASE))
    {
        __rodata_start = .;
        *(.rodata .rodata.*)
        *(.rodata.cst*)
        *(.rodata.str*)
        *(.eh_frame .eh_frame_hdr)
        __rodata_end = .;
    }

    /* Include eh_frame in rodata - don't create a separate segment */

    .data ALIGN(4K) : AT(KERNEL_PHYS_BASE + (ADDR(.data) - KERNEL_VIRT_BASE))
    {
        __data_start = .;
        *(.data .data.*)
        *(.data.rel.ro*)
        __data_end = .;
    }

    .bss ALIGN(4K) : AT(KERNEL_PHYS_BASE + (ADDR(.bss) - KERNEL_VIRT_BASE))
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    }

    . = ALIGN(4K);
    __kernel_end = .;
    __kernel_size = __kernel_end - __kernel_start;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
    }
}
