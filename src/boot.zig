const std = @import("std");
const uefi = std.os.uefi;

pub fn main() uefi.Status {
    return uefi.Status.LoadError;
}
