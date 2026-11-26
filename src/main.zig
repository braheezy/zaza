pub const std_options = @import("logging.zig").options;
const std = @import("std");
const replay = @import("replay.zig");
const Machine = @import("libzaza").Emulator;
const video = @import("libzaza").video;
const cartridge = @import("cartridge.zig");
const session_cli = @import("session.zig");
const screenshot = @import("screenshot.zig");

const demo = @import("mode3_demo.zig");

const usage =
    "Usage: zaza-cli [options] session <game.gba> [--record <transcript>]\n" ++
    "       zaza-cli [options] replay-session <game.gba> <transcript> [<image>]\n" ++
    "       zaza-cli [options] replay <game.gba> <frames> <image> [--input <script> | --input-file <path>] [--wav <output.wav>]\n" ++
    "       zaza-cli [options] snapshot <game.gba> <steps> <image>\n" ++
    "       zaza-cli demo <image>\n" ++
    "Image output: use a .png extension for PNG. The default is BMP.\n" ++
    "Options: --bios <file>, --boot, --save <file>, --save-type <type>\n";

pub fn main(init: std.process.Init) !void {
    try @import("logging.zig").load(init.io, init.arena.allocator());
    const arena = init.arena.allocator();
    var args = (try init.minimal.args.toSlice(arena))[1..];
    var options: cartridge.Options = .{};
    while (try options.take(&args)) {}
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        std.debug.print(usage, .{});
        return;
    }
    if (args.len > 0) {
        const command = args[0];
        if (std.mem.eql(u8, command, "replay")) return replay.replayInput(init.io, arena, options, args[1..]);
        if (std.mem.eql(u8, command, "session")) {
            if (args.len == 2) return session_cli.run(init, options, args[1], null);
            if (args.len == 4 and std.mem.eql(u8, args[2], "--record")) {
                return session_cli.run(init, options, args[1], args[3]);
            }
        }
        if (std.mem.eql(u8, command, "replay-session") and (args.len == 3 or args.len == 4)) {
            const output = if (args.len == 4) args[3] else null;
            return session_cli.replayTranscript(init, options, args[1], .{
                .transcript = args[2],
                .image = output,
            });
        }
        if (std.mem.eql(u8, command, "snapshot") and args.len == 4) {
            const steps = try std.fmt.parseInt(usize, args[2], 10);
            if (steps == 0) return error.InvalidStepCount;
            return snapshot(init, options, try cartridge.loadRom(init.io, arena, args[1]), steps, args[3]);
        }
        if (std.mem.eql(u8, command, "demo") and args.len == 2) {
            if (options.boot) return error.BootNeedsCartridge;
            return snapshot(init, options, &demo.rom, demo.steps, args[1]);
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

    try screenshot.write(init.io, init.gpa, output, &frame, .exclusive);
    if (save) |*session| try session.flush(init.io, machine.saveMemory());
}

fn captureMachineBitmap(machine: *Machine, steps: usize, frame: *video.Frame) !void {
    for (0..steps) |step| {
        const address = machine.instructionAddress();
        machine.stepTimed() catch |err| {
            std.debug.print("CPU stopped after {d} steps at 0x{x:0>8}\n", .{ step, address });
            return err;
        };
    }
    try machine.snapshotBitmap(frame);
}
