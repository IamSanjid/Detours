const builtin = @import("builtin");
const std = @import("std");

const is_0_14_01_later = builtin.zig_version.major == 0 and builtin.zig_version.minor > 14;

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("Detours", .{});
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows }, // only Windows is supported
    });
    const optimize = b.standardOptimizeOption(.{});

    // Only static library is supported by the official Makefile.
    const detours = b.addStaticLibrary(.{
        .name = "detours",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(detours);
    detours.installHeader(upstream.path("src/detours.h"), "detours.h");
    detours.installHeader(upstream.path("src/detver.h"), "detver.h");
    detours.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = detours_source_files,
        .flags = getCCFlags(b, optimize),
        .language = .cpp,
    });
    switch (target.result.cpu.arch) {
        .x86 => {
            detours.root_module.addCMacro("DETOURS_X86", "1");
        },
        .x86_64 => {
            detours.root_module.addCMacro("DETOURS_X64", "1");
            detours.root_module.addCMacro("DETOURS_64BIT", "1");
        },
        .arm => {
            detours.root_module.addCMacro("DETOURS_ARM", "1");
        },
        .aarch64 => {
            detours.root_module.addCMacro("DETOURS_ARM64", "1");
            detours.root_module.addCMacro("DETOURS_64BIT", "1");
        },
        else => {
            std.debug.panic("Unsupported CPU architecture: {}", .{target.result.cpu.arch});
        },
    }
    if (target.result.abi != .msvc) {
        detours.linkLibCpp();
        if (optimize == .Debug) {
            detours.linkSystemLibrary("ucrtbased");
        }
    }

    const test_step = b.step("test", "Runs the Detours unit tests");
    const test_exe = if (!is_0_14_01_later) b.addExecutable(.{
        .name = "unittests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = false,
            .sanitize_thread = false,
            .stack_check = false,
            .stack_protector = false,
        }),
    }) else b.addExecutable(.{
        .name = "unittests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = .off,
            .sanitize_thread = false,
            .stack_check = false,
            .stack_protector = false,
        }),
    });
    test_exe.subsystem = .Console;
    test_exe.addCSourceFiles(.{
        .root = b.path("tests"),
        .files = detours_test_source_files,
        .flags = getTestCCFlags(b, optimize),
        .language = .cpp,
    });
    test_exe.linkLibrary(detours);
    test_exe.linkSystemLibrary("kernel32");
    test_exe.linkSystemLibrary("rpcrt4");

    const test_runner = b.addRunArtifact(test_exe);
    test_runner.addArgs(&.{
        "--reporter",
        "console",
        "--success",
        "--durations",
        "yes",
    });
    test_step.dependOn(&test_runner.step);
}

/// References:
///   * https://github.com/microsoft/Detours/blob/main/system.mak
///   * https://github.com/microsoft/Detours/blob/main/src/Makefile
fn getCCFlags(b: *std.Build, optimize: std.builtin.OptimizeMode) []const []const u8 {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;

    flags.appendSlice(b.allocator, &.{
        "-fexceptions",
        "-fcxx-exceptions",
        "-DWIN32_LEAN_AND_MEAN",
        "-D_WIN32_WINNT=0x501",
    }) catch @panic("OOM");

    if (optimize == .Debug) {
        flags.append(b.allocator, "-DDETOUR_DEBUG=1") catch @panic("OOM");
        if (!is_0_14_01_later) {
            flags.append(b.allocator, "-D_DEBUG") catch @panic("OOM");
        }
    } else {
        flags.append(b.allocator, "-DDETOUR_DEBUG=0") catch @panic("OOM");
    }
    // The Detours library uses arithmatic operations on null pointers when iterating,
    // which causes undefined behavior. But in practice it's fine, since the library also
    // performs checks to ensure that the pointer is not null before dereferencing it.
    // But the arithmatic operations upsets the sanitizer, so we disable it.
    // Eg. https://github.com/microsoft/Detours/blob/9764cebcb1a75940e68fa83d6730ffaf0f669401/src/modules.cpp#L251
    flags.append(b.allocator, "-fno-sanitize=undefined") catch @panic("OOM");

    return flags.items;
}

fn getTestCCFlags(b: *std.Build, optimize: std.builtin.OptimizeMode) []const []const u8 {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;

    flags.appendSlice(b.allocator, &.{
        "-fexceptions",
        "-fcxx-exceptions",
        "-w", // Disable warnings
        "-DCATCH_CONFIG_NO_WINDOWS_SEH",
    }) catch @panic("OOM");

    if (optimize == .Debug) {
        flags.append(b.allocator, "-DDETOUR_DEBUG=1") catch @panic("OOM");
        if (!is_0_14_01_later) {
            flags.append(b.allocator, "-D_DEBUG") catch @panic("OOM");
        }
    } else {
        flags.append(b.allocator, "-DDETOUR_DEBUG=0") catch @panic("OOM");
    }

    return flags.items;
}

const detours_source_files: []const []const u8 = &.{
    "creatwth.cpp",
    "detours.cpp",
    "disasm.cpp",
    "disolarm.cpp",
    "disolarm64.cpp",
    "disolia64.cpp",
    "disolx64.cpp",
    "disolx86.cpp",
    "image.cpp",
    "modules.cpp",
};

const detours_test_source_files: []const []const u8 = &.{
    "corruptor.cpp",
    "main.cpp",
    "payload.cpp",
    "process_helpers.cpp",
    "test_image_api.cpp",
    "test_module_api.cpp",
};
