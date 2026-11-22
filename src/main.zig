pub const std_options: std.Options = replay.log_options;
const std = @import("std");
const replay = @import("replay.zig");
const Machine = @import("machine.zig");
const video = @import("video.zig");
const cartridge = @import("cartridge.zig");

const demo = @import("mode3_demo.zig");

const desktop = @import("build_options").desktop;
const usage = "Usage: zaza [options] <game.gba> (desktop build)\n" ++
    "       zaza [options] session <game.gba>\n" ++
    "       zaza [options] replay <game.gba> <frames> <output.bmp> [--input <script> | --input-file <path>] [--wav <output.wav>]\n" ++
    "       zaza [options] snapshot <game.gba> <steps> <output.bmp>\n" ++
    "       zaza demo <output.bmp>\n" ++
    "Options: --bios <file>, --boot, --save <file>, --save-type <type>; playback: --mute, --volume 0..100\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = (try init.minimal.args.toSlice(arena))[1..];
    var options: cartridge.Options = .{};
    var volume: u8 = 30;
    while (args.len != 0) {
        if (try options.take(&args)) continue;
        if (std.mem.eql(u8, args[0], "--mute")) {
            volume = 0;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "--volume") and args.len >= 2) {
            volume = try std.fmt.parseInt(u8, args[1], 10);
            if (volume > 100) return error.InvalidVolume;
            args = args[2..];
        } else break;
    }
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        std.debug.print(usage, .{});
        return;
    }
    if (args.len > 0) {
        const command = args[0];
        if (std.mem.eql(u8, command, "replay")) return replay.replayInput(init.io, arena, options, args[1..]);
        if (std.mem.eql(u8, command, "session") and args.len == 2) return @import("session.zig").run(init, options, args[1]);
        if (std.mem.eql(u8, command, "snapshot") and args.len == 4) {
            const steps = try std.fmt.parseInt(usize, args[2], 10);
            if (steps == 0) return error.InvalidStepCount;
            return snapshot(init, options, try cartridge.loadRom(init.io, arena, args[1]), steps, args[3]);
        }
        if (std.mem.eql(u8, command, "demo") and args.len == 2) {
            if (options.boot) return error.BootNeedsCartridge;
            return snapshot(init, options, &demo.rom, demo.steps, args[1]);
        }
        if (args.len == 1 and !std.mem.startsWith(u8, command, "-")) {
            if (desktop) return @import("desktop.zig").play(init, options, command, volume);
            return error.DesktopPlaybackUnavailable;
        }
    }
    std.debug.print(usage, .{});
    return error.InvalidArguments;
}

fn snapshot(init: std.process.Init, options: cartridge.Options, rom: []const u8, steps: usize, output: []const u8) !void {
    const arena = init.arena.allocator();
    var frame: video.Frame = undefined;
    var machine: Machine = undefined;
    var save = try options.start(&machine, init.io, arena, rom);
    defer if (save) |session| session.close(init.io);
    try captureMachineBitmap(&machine, steps, &frame);

    try replay.writeBitmap(init.io, output, &frame);
    if (save) |*session| try session.flush(init.io, &machine.bus.save);
}

fn captureMachineBitmap(machine: *Machine, steps: usize, frame: *video.Frame) !void {
    for (0..steps) |step| {
        const address = machine.cpu.instruction_address;
        machine.stepTimed() catch |err| {
            std.debug.print("CPU stopped after {d} steps at 0x{x:0>8}\n", .{ step, address });
            return err;
        };
    }
    try machine.snapshotBitmap(frame);
}
