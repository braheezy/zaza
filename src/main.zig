pub const std_options = @import("logging.zig").options;
const std = @import("std");
const replay = @import("replay.zig");
const Machine = @import("libzaza").Emulator;
const video = @import("libzaza").video;
const cartridge = @import("cartridge.zig");

const demo = @import("mode3_demo.zig");

const usage =
    "Usage: zaza-cli [options] session <game.gba>\n" ++
    "       zaza-cli [options] replay <game.gba> <frames> <output.bmp> [--input <script> | --input-file <path>] [--wav <output.wav>]\n" ++
    "       zaza-cli [options] snapshot <game.gba> <steps> <output.bmp>\n" ++
    "       zaza-cli demo <output.bmp>\n" ++
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
