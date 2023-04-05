const std = @import("std");
const uefi = std.os.uefi;

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;

pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out orelse return .Unsupported;

    var status: uefi.Status = undefined;

    status = con_out.clearScreen();
    if (status != .Success) return status;

    status = con_out.outputString(&[_:0]u16{ 'H', 'e', 'l', 'l', 'o', ' ', 'L', 'o', 'a', 'd', 'e', 'r', '!', '\r', '\n' });
    if (status != .Success) return status;

    while (true) {}

    return .LoadError;
}
