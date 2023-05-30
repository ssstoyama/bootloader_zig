const std = @import("std");
const uefi = std.os.uefi;
const elf = std.elf;

var bs: *uefi.tables.BootServices = undefined;
var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;
var gop: *uefi.protocols.GraphicsOutputProtocol = undefined;

pub fn main() uefi.Status {
    var status: uefi.Status = undefined;

    // ----------------------
    // ブートローダーの初期化処理
    // ----------------------

    // SimpleTextOutputProtocol 取得
    con_out = uefi.system_table.con_out orelse return .Unsupported;
    // 画面クリア
    status = con_out.clearScreen();
    if (status != .Success) {
        printf("failed to clear screen: {d}\r\n", .{status});
        return status;
    }

    // BootServices 取得
    bs = uefi.system_table.boot_services orelse {
        printf("unsupported boot services\r\n", .{});
        return .Unsupported;
    };

    // GraphicsOutputProtocol 取得
    status = bs.locateProtocol(&uefi.protocols.GraphicsOutputProtocol.guid, null, @ptrCast(*?*anyopaque, &gop));
    if (status != .Success) {
        printf("failed to locate graphics output protocol: {d}\r\n", .{status});
        return status;
    }

    printf("initialized boot loader\r\n", .{});

    // ----------------------
    // カーネルヘッダ取得
    // ----------------------

    // ルートディレクトリを開く
    var root_dir: *uefi.protocols.FileProtocol = undefined;
    status = openRootDir(&root_dir);
    if (status != .Success) {
        printf("failed to open root directory: {d}\r\n", .{status});
        return status;
    }
    printf("opened root directory\r\n", .{});

    printf("list files in root directory\r\n", .{});
    status = listDir(root_dir);
    if (status != .Success) {
        printf("failed to list root directory: {d}\r\n", .{status});
        return status;
    }

    // カーネルファイルを開く
    var kernel_file: *uefi.protocols.FileProtocol = undefined;
    status = root_dir.open(
        &kernel_file,
        &[_:0]u16{ 'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f' },
        uefi.protocols.FileProtocol.efi_file_mode_read,
        uefi.protocols.FileProtocol.efi_file_read_only,
    );
    if (status != .Success) {
        printf("failed to open kernel file: {d}\r\n", .{status});
        return status;
    }
    printf("opened kernel file\r\n", .{});

    // ヘッダ読み込み用のバッファ
    var header_buffer: [*]align(8) u8 = undefined;
    var header_size: usize = @sizeOf(elf.Elf64_Ehdr);
    // ヘッダ読み込み用のメモリを確保する
    status = bs.allocatePool(uefi.tables.MemoryType.LoaderData, header_size, &header_buffer);
    if (status != .Success) {
        printf("failed to allocate memory for kernel header: {d}\r\n", .{status});
        return status;
    }
    // kernel.elf の先頭からヘッダのみ読み込む
    status = kernel_file.read(&header_size, header_buffer);
    if (status != .Success) {
        printf("failed to read kernel header: {d}\r\n", .{status});
        return status;
    }
    // header_buffer を Header 構造体にパースする
    const header = elf.Header.parse(header_buffer[0..@sizeOf(elf.Elf64_Ehdr)]) catch |err| {
        printf("failed to parse kernel header: {}\r\n", .{err});
        return .LoadError;
    };
    printf("read kernel header\r\n", .{});

    // ----------------------
    // カーネルのロード
    // ----------------------

    // カーネルのロードに必要なメモリを確保するためにページ数(1ページ=4KiB)を計算する
    var kernel_first_addr: elf.Elf64_Addr align(4096) = std.math.maxInt(elf.Elf64_Addr);
    var kernel_last_addr: elf.Elf64_Addr = 0;
    var iter = header.program_header_iterator(kernel_file);
    while (true) {
        // プログラムヘッダを1つ読み込む
        const phdr = iter.next() catch |err| {
            printf("failed to iterate program headers: {}\r\n", .{err});
            return .LoadError;
        } orelse break;
        // プログラムヘッダタイプ LOAD 以外はスキップ
        if (phdr.p_type != elf.PT_LOAD) continue;
        if (phdr.p_vaddr < kernel_first_addr) {
            kernel_first_addr = phdr.p_vaddr;
        }
        if (phdr.p_vaddr + phdr.p_memsz > kernel_last_addr) {
            kernel_last_addr = phdr.p_vaddr + phdr.p_memsz;
        }
    }
    const pages = (kernel_last_addr - kernel_first_addr + 0xfff) / 0x1000; // 0x1000=4096
    printf("kernel first addr: 0x{x}, kernel last addr: 0x{x}, pages=0x{x}\r\n", .{ kernel_first_addr, kernel_last_addr, pages });

    // kernel_first_addr から pages ページ分のメモリを確保する
    status = bs.allocatePages(.AllocateAddress, .LoaderData, pages, @ptrCast(*[*]align(4096) u8, &kernel_first_addr));
    if (status != .Success) {
        printf("failed to allocate pages for kernel: {d}\r\n", .{status});
        return status;
    }
    printf("allocated pages for kernel\r\n", .{});

    iter = header.program_header_iterator(kernel_file);
    while (true) {
        // プログラムヘッダを1つ読み込む
        const phdr = iter.next() catch |err| {
            printf("failed to iterate program headers: {}\r\n", .{err});
            return .LoadError;
        } orelse break;
        // プログラムヘッダタイプ LOAD 以外はスキップ
        if (phdr.p_type != elf.PT_LOAD) continue;

        // ファイルの読み込み位置をあわせる
        // phdr.p_offset はカーネルファイルの先頭からのオフセット
        status = kernel_file.setPosition(phdr.p_offset);
        if (status != .Success) {
            printf("failed to set file position: {d}\r\n", .{status});
            return status;
        }

        // セグメント読み込み先のポインタ
        var segment: [*]u8 = @intToPtr([*]u8, phdr.p_vaddr);
        // セグメントのサイズ
        var mem_size: usize = phdr.p_memsz;
        // メモリにセグメントを読み込む
        status = kernel_file.read(&mem_size, segment);
        if (status != .Success) {
            printf("failed to load segment: {d}\r\n", .{status});
            return status;
        }
        printf(
            "load segment: addr=0x{x}, offset=0x{x}, mem_size=0x{x}\r\n",
            .{ phdr.p_vaddr, phdr.p_offset, phdr.p_memsz },
        );

        // 初期化していない変数がある場合はメモリの値を 0 で埋める。
        // bss セグメント(初期化していないグローバル変数用のセグメント)がある場合は必要。
        var zero_fill_count = phdr.p_memsz - phdr.p_filesz;
        if (zero_fill_count > 0) {
            bs.setMem(@intToPtr([*]u8, phdr.p_vaddr + phdr.p_filesz), zero_fill_count, 0);
        }
        printf("zero fill count: 0x{x}\r\n", .{zero_fill_count});
    }

    // ----------------------
    // カーネルに渡す情報(BootInfo)を用意する
    // ----------------------

    const frame_buffer_config = FrameBufferConfig{
        .frame_buffer = @intToPtr([*]u8, gop.mode.frame_buffer_base),
        .pixels_per_scan_line = gop.mode.info.pixels_per_scan_line,
        .horizontal_resolution = gop.mode.info.horizontal_resolution,
        .vertical_resolution = gop.mode.info.vertical_resolution,
        .pixel_format = switch (gop.mode.info.pixel_format) {
            .PixelRedGreenBlueReserved8BitPerColor => PixelFormat.PixelRGBResv8BitPerColor,
            .PixelBlueGreenRedReserved8BitPerColor => PixelFormat.PixelBGRResv8BitPerColor,
            else => unreachable,
        },
    };
    const boot_info = BootInfo{
        .frame_buffer_config = &frame_buffer_config,
    };
    printf("kernel entry point: 0x{x}\r\n", .{header.entry});
    printf("boot info pointer: {*}\r\n", .{&boot_info});

    // ----------------------
    // ブートサービス終了処理
    // ----------------------

    // 不要になったメモリ、ファイルの後始末
    status = bs.freePool(header_buffer);
    if (status != .Success) {
        printf("failed to free memory for kernel header: {d}\r\n", .{status});
        return status;
    }
    status = kernel_file.close();
    if (status != .Success) {
        printf("failed to close kernel file: {d}\r\n", .{status});
        return status;
    }
    status = root_dir.close();
    if (status != .Success) {
        printf("failed to close root directory: {d}\r\n", .{status});
        return status;
    }

    // map_key を取得してブートローダーを終了する
    var map_size: usize = 0;
    var descriptors: [*]uefi.tables.MemoryDescriptor = undefined;
    var map_key: usize = 0;
    var descriptor_size: usize = 0;
    var descriptor_version: u32 = 0;
    _ = bs.getMemoryMap(&map_size, descriptors, &map_key, &descriptor_size, &descriptor_version);
    status = bs.exitBootServices(uefi.handle, map_key);
    if (status != .Success) {
        printf("failed to exit boot services: {d}\r\n", .{status});
        return status;
    }

    // ----------------------
    // カーネル呼び出し
    // ----------------------
    const kernel_main = @intToPtr(*fn (*const BootInfo) callconv(.SysV) void, header.entry);
    kernel_main(&boot_info);

    return .LoadError;
}

pub const BootInfo = extern struct {
    frame_buffer_config: *const FrameBufferConfig,
};

pub const FrameBufferConfig = extern struct {
    frame_buffer: [*]u8,
    pixels_per_scan_line: u32,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixel_format: PixelFormat,
};

pub const PixelFormat = enum(u8) {
    PixelRGBResv8BitPerColor = 1,
    PixelBGRResv8BitPerColor = 2,
};

fn openRootDir(root_dir: **uefi.protocols.FileProtocol) uefi.Status {
    var status: uefi.Status = undefined;
    var loaded_image: *uefi.protocols.LoadedImageProtocol = undefined;
    var fs: *uefi.protocols.SimpleFileSystemProtocol = undefined;

    status = bs.openProtocol(
        uefi.handle,
        &uefi.protocols.LoadedImageProtocol.guid,
        @ptrCast(*?*anyopaque, &loaded_image),
        uefi.handle,
        null,
        .{ .by_handle_protocol = true },
    );
    if (status != .Success) {
        printf("failed to open loaded image protocol: {d}\r\n", .{status});
        return status;
    }

    var device_handle = loaded_image.device_handle orelse {
        printf("failed to get device handle\r\n", .{});
        return uefi.Status.Unsupported;
    };
    printf("loaded image: device_handle={*}\r\n", .{device_handle});
    status = bs.openProtocol(
        device_handle,
        &uefi.protocols.SimpleFileSystemProtocol.guid,
        @ptrCast(*?*anyopaque, &fs),
        uefi.handle,
        null,
        .{ .by_handle_protocol = true },
    );
    if (status != .Success) {
        printf("failed to open device handle: {d}\r\n", .{status});
        return status;
    }

    return fs.openVolume(root_dir);
}

fn listDir(dir: *uefi.protocols.FileProtocol) uefi.Status {
    var status: uefi.Status = undefined;
    var info_buffer: [1024]u8 align(8) = undefined;

    while (true) {
        var info_size: usize = info_buffer.len;
        status = dir.read(&info_size, info_buffer[0..]);
        if (status != .Success) return status;
        if (info_size == 0) break;

        var info: *uefi.protocols.FileInfo = @ptrCast(*uefi.protocols.FileInfo, &info_buffer);

        status = con_out.outputString(&[_:0]u16{ '-', ' ' });
        if (status != .Success) return status;
        status = con_out.outputString(info.getFileName());
        if (status != .Success) return status;
        status = con_out.outputString(&[_:0]u16{ '\r', '\n' });
        if (status != .Success) return status;
    }

    return uefi.Status.Success;
}

fn printf(comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, format, args) catch unreachable;
    for (text) |c| {
        con_out.outputString(&[_:0]u16{ c, 0 }).err() catch unreachable;
    }
}
