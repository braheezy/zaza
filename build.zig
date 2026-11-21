const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Declared output files make Run cache this download until its inputs change.
    const bios_download = b.addSystemCommand(&.{
        "curl",                                                                      "--fail",   "--location", "--silent", "--show-error",
        "https://github.com/coolbho3k/emibios/releases/download/0.2.1/gba_bios.bin", "--output",
    });
    const bios_image = bios_download.addOutputFileArg("gba_bios.bin");
    module.addAnonymousImport("emibios", .{ .root_source_file = bios_image });
    b.installFile("vendor/emibios/LICENSE", "share/licenses/emibios/LICENSE");
    b.installFile("vendor/emibios/NOTICE", "share/licenses/emibios/NOTICE");
    const executable = b.addExecutable(.{ .name = "zaza", .root_module = module });
    b.installArtifact(executable);

    const check = b.step("check", "Check the executable without installing it");
    check.dependOn(&executable.step);

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const cputest_enabled = b.option(bool, "cputest-internal", "Configure CPU vector tests") orelse false;
    if (!cputest_enabled) {
        const run_cputest = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "cputest",
            "-Dcputest-internal=true",
            b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        });
        run_cputest.addArg("--");
        run_cputest.addPassthruArgs();
        b.step("cputest", "Run supported ARM7TDMI SingleStepTests vectors").dependOn(&run_cputest.step);
        return;
    }

    const vectors = try b.dependencyLazy("arm7tdmi_vectors", .{});
    const runner = b.addExecutable(.{
        .name = "cputest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cputest.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    runner.root_module.addImport("cpu", b.createModule(.{
        .root_source_file = b.path("src/cpu.zig"),
    }));
    const styling = try b.dependencyLazy("chameleon", .{ .target = b.graph.host, .optimize = optimize });
    runner.root_module.addImport("chameleon", styling.module("chameleon"));
    const run_vectors = b.addRunArtifact(runner);
    run_vectors.addDirectoryArg2(vectors.path("v1"), .{});
    run_vectors.addPassthruArgs();
    b.step("cputest", "Run supported ARM7TDMI SingleStepTests vectors").dependOn(&run_vectors.step);
}
