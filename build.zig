const std = @import("std");
const Build = std.Build;
const Module = Build.Module;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // TODO: If this is accepted, then we can depend on zig build graph to fetch the bios
    // https://github.com/coolbho3k/emibios/issues/18
    const bios = bundledBios(b);

    const lib = b.addModule("libzaza", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addAnonymousImport("emibios", .{ .root_source_file = bios });

    // Load dependencies
    const parser = b.lazyDependency("ini", .{ .target = target, .optimize = optimize }) orelse return;

    // Ensure dependencies are attributed
    const notices = installNotices(b, parser);

    const imports = &[_]Module.Import{
        .{ .name = "libzaza", .module = lib },
        .{ .name = "ini", .module = parser.module("ini") },
    };
    // For lsp feedback
    const check = b.step("check", "Compile the frontends without installing them");
    // Headless usage
    const cli_step = b.step("cli", "Install the headless CLI");
    cli_step.dependOn(notices);
    const cli = installFrontend(b, cli_step, "zaza-cli", frontendModule(b, target, optimize, "src/main.zig", imports), check);
    runStep(b, "run-cli", "Run the headless CLI", b.addRunArtifact(cli));

    // Tests
    const desktop_supported = target.result.os.tag == .macos and b.dep_prefix.len == 0;
    addTests(b, target, optimize, bios, parser.module("ini"));
    addCpuTests(b, optimize);

    // Desktop app
    const desktop = b.step("desktop", "Install the macOS desktop player");
    if (desktop_supported) {
        desktop.dependOn(notices);
        addDesktop(b, target, optimize, imports, check, desktop);
    } else if (target.result.os.tag != .macos) {
        desktop.dependOn(&b.addFail("Desktop playback currently requires macOS.").step);
    }
}

fn bundledBios(b: *Build) Build.LazyPath {
    // A declared output lets Zig reuse the downloaded image across builds.
    const download = b.addSystemCommand(&.{ "curl", "--fail", "--location", "--silent", "--show-error" });
    download.addArgs(&.{ "https://github.com/coolbho3k/emibios/releases/download/0.2.1/gba_bios.bin", "--output" });
    return download.addOutputFileArg("gba_bios.bin");
}

fn installNotices(b: *Build, parser: *Build.Dependency) *Build.Step {
    const notices = b.step("notices", "Install dependency license notices");
    notices.dependOn(&b.addInstallFile(b.path("vendor/emibios/LICENSE"), "share/licenses/emibios/LICENSE").step);
    notices.dependOn(&b.addInstallFile(b.path("vendor/emibios/NOTICE"), "share/licenses/emibios/NOTICE").step);
    const licence = b.addInstallFile(parser.path("LICENCE"), "share/licenses/ini/LICENCE");
    notices.dependOn(&licence.step);
    return notices;
}

fn frontendModule(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8, imports: []const Module.Import) *Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .imports = imports });
}

fn installFrontend(b: *Build, step: *Build.Step, name: []const u8, module: *Module, check: *Build.Step) *Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = name, .root_module = module });
    check.dependOn(&exe.step);
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    b.getInstallStep().dependOn(step);
    return exe;
}

fn addDesktop(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, imports: []const Module.Import, check: *Build.Step, desktop: *Build.Step) void {
    const dep = b.lazyDependency("mach", .{
        .target = target,
        .optimize = optimize,
        .core = true,
        .sysaudio = true,
    }) orelse return;
    const mach = dep.module("mach");
    const app = frontendModule(b, target, optimize, "src/app.zig", imports);
    app.addImport("mach", mach);
    // Mach adds its Objective-C bridge after Zig fetches the lazy desktop dependencies.
    app.addImport("objc", mach.import_table.get("objc") orelse return);
    app.linkFramework("UniformTypeIdentifiers", .{});
    const player = installFrontend(b, desktop, "zaza", app, check);
    runStep(b, "run", "Run the desktop player", b.addRunArtifact(player));
}

fn addTests(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, bios: Build.LazyPath, ini: *Module) void {
    const rom = b.addWriteFiles().add("direct-sound.gba", &@import("test/direct_sound_rom.zig").rom);
    const install = b.addInstallFile(rom, "roms/direct-sound.gba");
    b.step("audio-test-rom", "Install the silent Direct Sound test cartridge").dependOn(&install.step);

    const module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize });
    module.addImport("libzaza", module);
    module.addImport("ini", ini);
    module.addAnonymousImport("direct_sound_rom", .{ .root_source_file = rom });
    module.addAnonymousImport("emibios", .{ .root_source_file = bios });
    const checkpoint = b.option([]const u8, "checkpoint-rom", "Additional cartridge for the frame-360 checkpoint test");
    const options = b.addOptions();
    options.addOption(bool, "external_checkpoint", checkpoint != null);
    module.addOptions("test_options", options);
    if (checkpoint) |path| module.addAnonymousImport("checkpoint_rom", .{ .root_source_file = b.path(path) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

fn addCpuTests(b: *Build, optimize: std.builtin.OptimizeMode) void {
    // Configure the host runner and fetch its vectors only when cputest is requested.
    const description = "Run supported ARM7TDMI SingleStepTests vectors";
    if (!(b.option(bool, "cputest-internal", "Configure CPU vector tests") orelse false)) {
        const command = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "cputest", "-Dcputest-internal=true" });
        command.addArgs(&.{ b.fmt("-Doptimize={s}", .{@tagName(optimize)}), "--" });
        runStep(b, "cputest", description, command);
        return;
    }

    const vectors = b.lazyDependency("arm7tdmi_vectors", .{}) orelse return;
    const styling = b.lazyDependency("chameleon", .{ .target = b.graph.host, .optimize = optimize }) orelse return;
    const module = b.createModule(.{ .root_source_file = b.path("test/cputest.zig"), .target = b.graph.host, .optimize = optimize });
    module.addImport("cpu", b.createModule(.{ .root_source_file = b.path("src/cpu.zig") }));
    module.addImport("chameleon", styling.module("chameleon"));
    const exe = b.addExecutable(.{ .name = "cputest", .root_module = module });
    const run = b.addRunArtifact(exe);
    run.addDirectoryArg(vectors.path("v1"));
    runStep(b, "cputest", description, run);
}

fn runStep(b: *Build, name: []const u8, description: []const u8, run: *Build.Step.Run) void {
    if (b.args) |args| run.addArgs(args);
    b.step(name, description).dependOn(&run.step);
}
