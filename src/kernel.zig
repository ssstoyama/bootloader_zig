const BootInfo = @import("boot.zig").BootInfo;

export fn kernel_main(boot_info: *const BootInfo) void {
    _ = boot_info;
    while (true) asm volatile ("hlt");
}
