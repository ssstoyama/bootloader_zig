export fn kernel_main() void {
    while (true) asm volatile ("hlt");
}
