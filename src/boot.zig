const std = @import("std");
const uefi = std.os.uefi;

pub fn main() uefi.Status {
    while (true) {}
    return uefi.Status.LoadError;
}
