const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cc-statusline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run cc-statusline");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // strip-dwarf: patch DWARF v5 for GNU tool compatibility
    const strip_dwarf = b.addExecutable(.{
        .name = "strip-dwarf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/strip_dwarf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(strip_dwarf);

    const strip_dwarf_tests = b.addTest(.{
        .root_module = strip_dwarf.root_module,
    });
    const run_strip_dwarf_tests = b.addRunArtifact(strip_dwarf_tests);
    test_step.dependOn(&run_strip_dwarf_tests.step);

    // Coverage step: zig build cover
    const cover_step = b.step("cover", "Generate test coverage (Linux: gdb, macOS: lldb)");
    const run_cover = b.addSystemCommand(&.{
        "bash",
        "scripts/cover.sh",
    });
    cover_step.dependOn(&run_cover.step);

    // Bench step: zig build bench [-- --save] [-- --size=small|medium|large]
    // Built ReleaseFast unconditionally so numbers reflect production behavior;
    // the macro bench spawns whatever `exe` was built with `optimize`, so
    // prefer `zig build bench -Doptimize=ReleaseFast` for both layers.
    const bench = b.addExecutable(.{
        .name = "cc-statusline-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = false,
        }),
    });

    const bench_step = b.step("bench", "Run benchmarks (-- --save updates baseline, -- --size=NAME filters)");
    const run_bench = b.addRunArtifact(bench);
    run_bench.addArtifactArg(exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    bench_step.dependOn(&run_bench.step);
    run_bench.step.dependOn(b.getInstallStep());
}
