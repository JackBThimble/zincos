pub const MAX_MEMORY_REGIONS = 512;
pub const BOOT_MAGIC: u64 = 0xB007_1AF0_DEAD_BEEF;

pub const FramebufferInfo = extern struct {
    base_address: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u16,
    pixel_format: PixelFormat,
    _reserved: u8,
};

pub const PixelFormat = enum(u8) {
    rgb = 0,
    bgr = 1,
    bitmask = 2,
    blt_only = 3,
    unknown = 255,
};

pub const MemoryRegion = extern struct {
    base: u64,
    length: u64,
    kind: MemoryKind,
    _reserved0: u8,
    _reserved1: u8,
    _reserved2: u8,
    _padding: u32,
};

pub const MemoryKind = enum(u8) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

pub const BootInfo = extern struct {
    magic: u64,
    framebuffer: FramebufferInfo,
    memory_map_addr: u64,
    memory_map_entries: u64,
    kernel_physical_base: u64,
    kernel_virtual_base: u64,
    kernel_size: u64,
    initrd_addr: u64,
    initrd_size: u64,
    rsdp_address: u64,
    hhdm_base: u64,
    cpu_count: u64,
};
