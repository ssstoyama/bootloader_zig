const std = @import("std");
const uefi = std.os.uefi;
const elf = std.elf;

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;
var bs: *uefi.tables.BootServices = undefined;
var fs: *uefi.protocols.SimpleFileSystemProtocol = undefined;

pub fn main() uefi.Status {
    var status: uefi.Status = undefined;

    // 1. ブートローダーの初期化処理

    // SimpleTextOutputProtocol 取得
    con_out = uefi.system_table.con_out orelse return .Unsupported;
    defer {
        printf("boot error: status={d}\r\n", .{status});
        while (true) asm volatile ("hlt");
    }
    status = con_out.clearScreen();
    if (status != .Success) return status;

    // BootServices 取得
    bs = uefi.system_table.boot_services orelse return .Unsupported;

    // SimpleFileSystemProtocol 取得
    status = bs.locateProtocol(&uefi.protocols.SimpleFileSystemProtocol.guid, null, @ptrCast(*?*anyopaque, &fs));
    if (status != .Success) return status;

    printf("initialized boot loader\r\n", .{});

    // 2. カーネルのヘッダを読み込む

    // ルートディレクトリを開く
    var root_dir: *uefi.protocols.FileProtocol = undefined;
    status = fs.openVolume(&root_dir);
    if (status != .Success) return status;
    printf("opened root directory\r\n", .{});

    // カーネルファイルを開く
    var kernel_file: *uefi.protocols.FileProtocol = undefined;
    status = root_dir.open(
        &kernel_file,
        &[_:0]u16{ 'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f' },
        uefi.protocols.FileProtocol.efi_file_mode_read,
        uefi.protocols.FileProtocol.efi_file_read_only,
    );
    if (status != .Success) return status;
    printf("opened kernel file\r\n", .{});

    var header_buffer: [*]align(8) u8 = undefined;
    var header_size: usize = @sizeOf(elf.Elf64_Ehdr);
    // ヘッダ読み込み用のメモリを用意する
    status = bs.allocatePool(uefi.tables.MemoryType.LoaderData, header_size, &header_buffer);
    if (status != .Success) return status;
    // kernel.elf からヘッダを読み込む
    status = kernel_file.read(&header_size, header_buffer);
    if (status != .Success) return status;
    // header_buffer を Header 構造体にパースする
    const header = elf.Header.parse(header_buffer[0..@sizeOf(elf.Elf64_Ehdr)]) catch |err| {
        printf("failed to parse kernel header: {}\r\n", .{err});
        return .LoadError;
    };
    printf("read kernel header: entry_point=0x{x}\r\n", .{header.entry});

    // 3. カーネルのロードに必要なメモリを確保する

    // カーネルのロードに必要なメモリを確保するためにページ数(1ページ=4KiB)を計算する
    var kernel_first_addr: elf.Elf64_Addr align(4096) = std.math.maxInt(elf.Elf64_Addr);
    var kernel_last_addr: elf.Elf64_Addr = 0;
    var iter = header.program_header_iterator(kernel_file);
    while (try iter.next()) |phdr| {
        // プログラムヘッダタイプ LOAD 以外はスキップ
        if (phdr.p_type != elf.PT_LOAD) continue;
        if (phdr.p_vaddr < kernel_first_addr) {
            kernel_first_addr = phdr.p_vaddr;
        }
        if (phdr.p_vaddr + phdr.p_memsz > kernel_last_addr) {
            kernel_last_addr = phdr.p_vaddr + phdr.p_memsz;
        }
    }
    // カーネルが収まるようにページ数(=メモリのサイズ)を計算する
    const pages = (kernel_last_addr - kernel_first_addr + 0xfff) / 0x1000; // 0x1000=4096
    printf("kernel first addr: 0x{x}, kernel last addr: 0x{x}, pages=0x{x}\r\n", .{ kernel_first_addr, kernel_last_addr, pages });

    // kernel_first_addr から pages ページ分のメモリを確保する
    status = bs.allocatePages(.AllocateAddress, .LoaderData, pages, @ptrCast(*[*]align(4096) u8, &kernel_first_addr));
    if (status != .Success) return status;
    printf("allocated pages for kernel\r\n", .{});

    while (true) {}

    return .LoadError;
}

fn printf(comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch unreachable;
    for (text) |c| {
        con_out.outputString(&[_:0]u16{ c, 0 }).err() catch unreachable;
    }
}
