const std = @import("std");
const uefi = std.os.uefi;

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;
var bs: *uefi.tables.BootServices = undefined;
var fs: *uefi.protocols.SimpleFileSystemProtocol = undefined;

pub fn main() uefi.Status {
    var status: uefi.Status = undefined;

    con_out = uefi.system_table.con_out orelse return .Unsupported;
    defer {
        printf("boot error: status={d}\r\n", .{status});
        while (true) asm volatile ("hlt");
    }
    status = con_out.clearScreen();
    if (status != .Success) return status;

    bs = uefi.system_table.boot_services orelse return .Unsupported;
    status = bs.locateProtocol(&uefi.protocols.SimpleFileSystemProtocol.guid, null, @ptrCast(*?*anyopaque, &fs));
    if (status != .Success) return status;

    printf("initialized boot loader\r\n", .{});

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
