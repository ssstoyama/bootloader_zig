const std = @import("std");

pub fn build(b: *std.Build) !void {
    const loader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/boot.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
        },
        .linkage = .static,
    });
    loader.setOutputDir("fs/efi/boot");
    loader.install();

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .ofmt = .elf,
        },
        .linkage = .static,
    });
    kernel.image_base = 0x100000;
    kernel.entry_symbol_name = "kernel_main";
    kernel.is_linking_libc = false;
    kernel.is_linking_libcpp = false;
    kernel.setOutputDir("fs");
    kernel.install();

    const qemu = qemuCommand(b);
    qemu.step.dependOn(&loader.step);
    qemu.step.dependOn(&kernel.step);

    const run_qemu = b.step("run", "run in qemu");
    run_qemu.dependOn(&qemu.step);
}

fn qemuCommand(b: *std.Build) *std.Build.RunStep {
    const is_debug = b.option(bool, "debug", "debugging in qemu") orelse false;

    const args = [_][]const u8{
        "qemu-system-x86_64",
        "-m",
        "1G",
        "-bios",
        "/usr/share/ovmf/OVMF.fd",
        "-hda",
        "fat:rw:fs",
        "-monitor",
        "stdio",
    };
    if (is_debug) {
        const debug_args = args ++ [_][]const u8{ "-s", "-S" };
        return b.addSystemCommand(&debug_args);
    }
    return b.addSystemCommand(&args);
}
