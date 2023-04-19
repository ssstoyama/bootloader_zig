pub fn startKernel(entry_point: u64, boot_info: *const anyopaque) void {
    // RDI レジスタ(第1引数)に BootInfo 構造体へのポインタを渡す
    // RAX レジスタに関数のアドレスを渡して実行する
    asm volatile (
        \\ callq *%rax
        :
        : [entry_point] "{rax}" (entry_point),
          [boot_info] "{rdi}" (boot_info),
    );
}

pub fn halt() void {
    while (true) asm volatile ("hlt");
}
