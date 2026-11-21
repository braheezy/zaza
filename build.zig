const std = @import("std");

pub fn build(b: *std.Build) void {
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

    const window_step = b.step("window", "Run the Mach framebuffer viewer (-Ddesktop=true)");
    const desktop_enabled = b.option(bool, "desktop", "Build the macOS Mach framebuffer viewer") orelse false;
    if (desktop_enabled and target.result.os.tag != .macos) {
        const unsupported = b.addFail("The Mach framebuffer viewer currently supports macOS.");
        b.getInstallStep().dependOn(&unsupported.step);
        check.dependOn(&unsupported.step);
        window_step.dependOn(&unsupported.step);
    } else if (desktop_enabled) {
        if (b.lazyDependency("mach", .{ .target = target, .optimize = optimize, .core = true })) |mach| {
            const desktop = b.addExecutable(.{
                .name = "zaza-window",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/desktop.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            const mach_module = mach.module("mach");
            desktop.root_module.addImport("mach", mach_module);
            // Share Mach's AppKit bindings for native window options Core does not expose.
            if (mach_module.import_table.get("objc")) |objc_module| {
                desktop.root_module.addImport("objc", objc_module);
            }
            desktop.root_module.addAnonymousImport("emibios", .{ .root_source_file = bios_image });
            b.installArtifact(desktop);
            check.dependOn(&desktop.step);
            const run = b.addRunArtifact(desktop);
            if (b.args) |args| run.addArgs(args);
            window_step.dependOn(&run.step);
        }
    } else {
        window_step.dependOn(&b.addFail("Use zig build window -Ddesktop=true -- <rom.gba> <steps>").step);
    }

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
        if (b.args) |args| run_cputest.addArgs(args);
        b.step("cputest", "Run supported ARM7TDMI SingleStepTests vectors").dependOn(&run_cputest.step);
        return;
    }

    const vectors = b.lazyDependency("arm7tdmi_vectors", .{}) orelse return;
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
    const styling = b.lazyDependency("chameleon", .{ .target = b.graph.host, .optimize = optimize }) orelse return;
    runner.root_module.addImport("chameleon", styling.module("chameleon"));
    const run_vectors = b.addRunArtifact(runner);
    run_vectors.addDirectoryArg(vectors.path("v1"));
    if (b.args) |args| run_vectors.addArgs(args);
    b.step("cputest", "Run supported ARM7TDMI SingleStepTests vectors").dependOn(&run_vectors.step);
}
