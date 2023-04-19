pub fn startKernel(entry_point: u64, boot_info: *const anyopaque) void {
    // A1 レジスタ(第1引数)に BootInfo 構造体へのポインタを渡す
    // v1 レジスタに関数のアドレスを渡して実行する
    asm volatile (
        \\ blr x8
        :
        : [entry_point] "{x8}" (entry_point),
          [boot_info] "{x0}" (boot_info),
    );
}

pub fn halt() void {
    while (true) {}
}
