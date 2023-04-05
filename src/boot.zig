const std = @import("std");
const uefi = std.os.uefi;

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;

pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out orelse return .Unsupported;

    var status: uefi.Status = undefined;

    status = con_out.clearScreen();
    if (status != .Success) return status;

    printf("Hello, {s}!\r\n", .{"Loader"});

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
