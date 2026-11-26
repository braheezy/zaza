const std = @import("std");
const zaza = @import("libzaza");
const wav = @import("wav.zig");
const Machine = @import("libzaza").Emulator;
const video = @import("libzaza").video;
const screenshot = @import("screenshot.zig");
const input = @import("libzaza").input;
const cartridge = @import("cartridge.zig");

pub fn replayInput(
    io: std.Io,
    arena: std.mem.Allocator,
    options: cartridge.Options,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3 or (args.len - 3) % 2 != 0) return error.InvalidReplayArguments;
    const frames = try std.fmt.parseInt(u32, args[1], 10);
    if (frames == 0) return error.InvalidFrameCount;
    var script: ?[]const u8 = null;
    var wav_path: ?[]const u8 = null;
    var option: usize = 3;
    while (option < args.len) : (option += 2) {
        const name = args[option];
        const value = args[option + 1];
        if (std.mem.eql(u8, name, "--wav") and wav_path == null) {
            wav_path = value;
        } else if (std.mem.eql(u8, name, "--input") and script == null) {
            script = value;
        } else if (std.mem.eql(u8, name, "--input-file") and script == null) {
            script = try std.Io.Dir.cwd().readFileAlloc(io, value, arena, .limited(1024 * 1024));
        } else return error.InvalidReplayArguments;
    }
    const changes = try input.parseScript(arena, script orelse "");
    if (changes.len != 0 and changes[changes.len - 1].frame >= frames) {
        return error.InputFrameOutsideReplay;
    }

    const rom = try cartridge.loadRom(io, arena, args[0]);
    var machine: Machine = undefined;
    var save = try options.start(&machine, io, arena, rom);
    defer if (save) |session| session.close(io);
    var wav_file = if (wav_path) |path| try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = false }) else null;
    defer if (wav_file) |*file| file.deinit(io);
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.File.Writer = undefined;
    var capture: zaza.AudioCapture = undefined;
    if (wav_file) |*file| {
        writer = file.file.writer(io, &buffer);
        try writer.interface.writeAll(&wav.header(0));
        capture = .{ .writer = &writer.interface };
        machine.setAudioCapture(&capture);
    }
    var replay: input.Replay = .{ .remaining = changes };
    for (0..frames) |index| {
        machine.runFrame(replay.buttonsForFrame(@intCast(index))) catch |err| {
            std.log.err("replay stopped in frame {d} at 0x{x:0>8}", .{
                index, machine.instructionAddress(),
            });
            return err;
        };
    }
    var frame: video.Frame = undefined;
    try machine.snapshotFrame(&frame);
    try screenshot.write(io, arena, args[2], &frame, .exclusive);
    if (wav_file) |*file| {
        try writer.interface.flush();
        try file.file.writePositionalAll(io, &wav.header(capture.bytes), 0);
        try file.link(io);
    }
    if (save) |*session| try session.flush(io, machine.saveMemory());
}
