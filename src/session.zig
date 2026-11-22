const std = @import("std");
const cartridge = @import("cartridge.zig");
const input = @import("libzaza").input;
const Machine = @import("libzaza").Emulator;
const video = @import("libzaza").video;
const replay = @import("replay.zig");

// stdin drives the emulated clock. stdout carries exactly one reply per request.
pub fn run(init: std.process.Init, options: cartridge.Options, path: []const u8) !void {
    const allocator = init.arena.allocator();
    const machine = try allocator.create(Machine);
    const rom = try cartridge.loadRom(init.io, allocator, path);
    var save = try options.start(machine, init.io, allocator, rom);
    defer if (save) |s| s.close(init.io);
    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &in_buffer);
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    const Slot = struct { machine: Machine.Checkpoint, frame: u64 };
    var checkpoint: ?*Slot = null;
    var frame: u64 = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        const command = parse(line) catch |err| {
            try writer.interface.print("error {s}\n", .{@errorName(err)});
            try writer.interface.flush();
            continue;
        };
        switch (command) {
            .quit => break,
            .checkpoint => {
                const slot = checkpoint orelse try allocator.create(Slot);
                machine.checkpoint(&slot.machine);
                slot.frame = frame;
                checkpoint = slot;
            },
            .restore => {
                const slot = checkpoint orelse {
                    try writer.interface.writeAll("error NoCheckpoint\n");
                    try writer.interface.flush();
                    continue;
                };
                machine.restore(&slot.machine);
                frame = slot.frame;
            },
            .step => |step| for (0..step.frames) |_| {
                try machine.runFrame(step.buttons);
                frame += 1;
            },
            .screen => |output| {
                var pixels: video.Frame = undefined;
                machine.snapshotFrame(&pixels) catch |err| {
                    try writer.interface.print("error {s}\n", .{@errorName(err)});
                    try writer.interface.flush();
                    continue;
                };
                replay.writeBitmap(init.io, output, &pixels) catch |err| {
                    try writer.interface.print("error {s}\n", .{@errorName(err)});
                    try writer.interface.flush();
                    continue;
                };
            },
        }
        try writer.interface.print("ok {d}\n", .{frame});
        try writer.interface.flush();
    }
    if (save) |*s| try s.flush(init.io, machine.saveMemory());
}

const Command = union(enum) {
    quit,
    checkpoint,
    restore,
    step: struct { frames: u32, buttons: input.Buttons },
    screen: []const u8,
};

fn parse(line: []const u8) !Command {
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    const verb = words.next() orelse return error.EmptyCommand;
    if (std.mem.eql(u8, verb, "quit") and words.next() == null) return .quit;
    if (std.mem.eql(u8, verb, "checkpoint") and words.next() == null) return .checkpoint;
    if (std.mem.eql(u8, verb, "restore") and words.next() == null) return .restore;
    if (std.mem.eql(u8, verb, "screen")) {
        const path = std.mem.trim(u8, words.rest(), " \t\r");
        if (path.len == 0) return error.MissingOutputPath;
        return .{ .screen = path };
    }
    if (std.mem.eql(u8, verb, "step")) {
        const count = words.next() orelse return error.MissingFrameCount;
        const frames = try std.fmt.parseInt(u32, count, 10);
        if (frames == 0) return error.InvalidFrameCount;
        return .{ .step = .{ .frames = frames, .buttons = try input.parseButtons(&words) } };
    }
    return error.UnknownCommand;
}
