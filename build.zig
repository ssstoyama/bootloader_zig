const std = @import("std");

pub fn build(b: *std.Build) !void {
    const is_debug = b.option(bool, "debug", "debugging in qemu") orelse false;

    const is_clean = b.option(bool, "clean", "clean output and cache") orelse false;
    if (is_clean) {
        try runClean(b);
    }

    const cpu_arch: std.Target.Cpu.Arch = getCpuArch(b);

    var optimize: std.builtin.Mode = .ReleaseSafe;
    if (is_debug) {
        optimize = .Debug;
    }

    const arch_module = switch (cpu_arch) {
        .x86_64 => b.createModule(.{
            .source_file = .{ .path = "src/arch/x86_64.zig" },
        }),
        .aarch64 => b.createModule(.{
            .source_file = .{ .path = "src/arch/aarch64.zig" },
        }),
        else => @panic("unknown cpu_arch"),
    };
    const loader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "src/boot.zig" },
        .target = .{
            .cpu_arch = cpu_arch,
            .os_tag = .uefi,
        },
        .optimize = optimize,
        .linkage = .static,
    });
    loader.addModule("arch", arch_module);
    loader.setOutputDir("fs/efi/boot");
    loader.install();

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = .{ .path = "src/kernel.zig" },
        .target = .{
            .cpu_arch = cpu_arch,
            .os_tag = .freestanding,
            .ofmt = .elf,
        },
        .optimize = optimize,
        .linkage = .static,
    });
    kernel.addModule("arch", arch_module);
    kernel.image_base = 0x100000;
    kernel.entry_symbol_name = "kernel_main";
    kernel.is_linking_libc = false;
    kernel.is_linking_libcpp = false;
    kernel.setOutputDir("fs");
    kernel.install();

    const qemu = qemuCommand(b, is_debug, cpu_arch);
    qemu.step.dependOn(&loader.step);
    qemu.step.dependOn(&kernel.step);

    const run_qemu = b.step("run", "run in qemu");
    run_qemu.dependOn(&qemu.step);
}

fn qemuCommand(b: *std.Build, is_debug: bool, cpu_arch: std.Target.Cpu.Arch) *std.Build.RunStep {
    const qemu: []const u8 = switch (cpu_arch) {
        .x86_64 => "qemu-system-x86_64",
        .aarch64 => "qemu-system-aarch64",
        else => @panic("unknown cpu_arch"),
    };
    const args = [_][]const u8{
        qemu,
        "-machine",
        "virt",
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

fn runClean(b: *std.Build) !void {
    const rm_args_list = [_][3][]const u8{
        [3][]const u8{ "rm", "-rf", "fs" },
        [3][]const u8{ "rm", "-rf", "zig-cache" },
        [3][]const u8{ "rm", "-rf", "zig-out" },
    };
    for (rm_args_list) |rm_args| {
        var rm_process = std.ChildProcess.init(&rm_args, b.allocator);
        _ = try rm_process.spawnAndWait();
    }
}

fn getCpuArch(b: *std.Build) std.Target.Cpu.Arch {
    var cpu_arch: []const u8 = b.option([]const u8, "cpu_arch", "build for arch (x86_64, aarch64)") orelse return .x86_64;
    if (std.mem.eql(u8, cpu_arch, "x86_64")) {
        return .x86_64;
    }
    if (std.mem.eql(u8, cpu_arch, "aarch64")) {
        return .aarch64;
    }
    @panic("unknown cpu_arch");
}
