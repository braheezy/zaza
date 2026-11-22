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

    const audio_rom = b.addWriteFiles().add("direct-sound.gba", &@import("test/direct_sound_rom.zig").rom);
    const install_rom = b.addInstallFile(audio_rom, "roms/direct-sound.gba");
    b.step("audio-test-rom", "Install the silent Direct Sound test cartridge").dependOn(&install_rom.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/machine_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addAnonymousImport("direct_sound_rom", .{ .root_source_file = audio_rom });
    test_module.addAnonymousImport("emibios", .{ .root_source_file = bios_image });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const desktop_enabled = b.option(bool, "desktop", "Include the macOS desktop player") orelse (target.result.os.tag == .macos);
    const options = b.addOptions();
    options.addOption(bool, "desktop", desktop_enabled);
    module.addOptions("build_options", options);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Zaza").dependOn(&run.step);
    if (desktop_enabled) {
        if (target.result.os.tag != .macos) {
            executable.step.dependOn(&b.addFail("Desktop playback currently requires macOS. Use -Ddesktop=false for automation.").step);
        } else if (b.lazyDependency("mach", .{ .target = target, .optimize = optimize, .core = true, .sysaudio = true })) |mach| {
            const mach_module = mach.module("mach");
            module.addImport("mach", mach_module);
            module.addImport("objc", mach_module.import_table.get("objc").?);
        }
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
