const std = @import("std");
const cartridge = @import("cartridge.zig");
const zaza = @import("libzaza");
const input = zaza.input;
const video = zaza.video;
const screenshot = @import("screenshot.zig");

const transcript_version = "zaza-session 1";
const Digest = [32]u8;
const Blake3 = std.crypto.hash.Blake3;

// stdin drives the emulated clock. stdout carries exactly one reply per request.
pub fn run(
    init: std.process.Init,
    options: cartridge.Options,
    path: []const u8,
    record_path: ?[]const u8,
) !void {
    const arena = init.arena.allocator();
    const machine = try arena.create(zaza.Emulator);
    const rom = try cartridge.loadRom(init.io, arena, path);
    const emulator_options = try options.emulatorOptions(init.io, arena);
    try machine.init(rom, emulator_options);
    var save = try options.save.open(init.io, arena, machine.saveMemory());
    defer if (save) |session| session.close(init.io);

    var recording = if (record_path) |output|
        try std.Io.Dir.cwd().createFileAtomic(init.io, output, .{ .replace = false })
    else
        null;
    defer if (recording) |*file| file.deinit(init.io);
    var record_buffer: [4096]u8 = undefined;
    var record_file_writer: std.Io.File.Writer = undefined;
    const record_writer = if (recording) |*file| writer: {
        record_file_writer = file.file.writer(init.io, &record_buffer);
        var header_buffer: [256]u8 = undefined;
        const header = try transcriptHeader(&header_buffer, rom, emulator_options, machine);
        try record_file_writer.interface.print("{s}\n{s}\n", .{ transcript_version, header });
        break :writer &record_file_writer.interface;
    } else null;

    var in_buffer: [4096]u8 = undefined;
    var out_buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &in_buffer);
    var writer = std.Io.File.stdout().writer(init.io, &out_buffer);
    var state: State = .{ .machine = machine };
    while (try reader.interface.takeDelimiter('\n')) |line| {
        const command = parse(line) catch |err| {
            try replyError(&writer.interface, err);
            continue;
        };
        switch (command) {
            .quit => break,
            .control => |control| {
                state.apply(arena, control) catch |err| switch (err) {
                    error.NoCheckpoint => {
                        try replyError(&writer.interface, err);
                        continue;
                    },
                    else => return err,
                };
                if (record_writer) |output| try output.print("{s}\n", .{line});
            },
            .screen => |output| {
                var pixels: video.Frame = undefined;
                machine.snapshotFrame(&pixels) catch |err| {
                    try replyError(&writer.interface, err);
                    continue;
                };
                screenshot.write(init.io, init.gpa, output, &pixels, .exclusive) catch |err| {
                    try replyError(&writer.interface, err);
                    continue;
                };
            },
        }
        try writer.interface.print("ok {d}\n", .{state.frame});
        try writer.interface.flush();
    }
    if (recording) |*file| {
        var pixels: video.Frame = undefined;
        const digest = frameDigest(machine, &pixels);
        var footer_buffer: [128]u8 = undefined;
        const footer = try transcriptFooter(&footer_buffer, state.frame, digest);
        try record_file_writer.interface.print("{s}\n", .{footer});
        try record_file_writer.interface.flush();
        try file.link(init.io);
    }
    if (save) |*session| try session.flush(init.io, machine.saveMemory());
}

pub fn replayTranscript(
    init: std.process.Init,
    options: cartridge.Options,
    rom_path: []const u8,
    paths: struct { transcript: []const u8, image: ?[]const u8 },
) !void {
    const file = try std.Io.Dir.cwd().openFile(init.io, paths.transcript, .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &buffer);
    const reader = &file_reader.interface;
    const version = try reader.takeDelimiter('\n') orelse return error.IncompleteTranscript;
    if (!std.mem.eql(u8, version, transcript_version)) return error.UnsupportedTranscriptVersion;

    const arena = init.arena.allocator();
    const rom = try cartridge.loadRom(init.io, arena, rom_path);
    const emulator_options = try options.emulatorOptions(init.io, arena);
    const machine = try arena.create(zaza.Emulator);
    try machine.init(rom, emulator_options);
    try options.save.loadInitial(init.io, arena, machine.saveMemory());
    var header_buffer: [256]u8 = undefined;
    const expected_header = try transcriptHeader(&header_buffer, rom, emulator_options, machine);
    const header = try reader.takeDelimiter('\n') orelse return error.IncompleteTranscript;
    if (!std.mem.eql(u8, header, expected_header)) return error.TranscriptStartMismatch;

    var state: State = .{ .machine = machine };
    while (try reader.takeDelimiter('\n')) |line| {
        if (std.mem.startsWith(u8, line, "end ")) {
            var pixels: video.Frame = undefined;
            const digest = frameDigest(machine, &pixels);
            var footer_buffer: [128]u8 = undefined;
            const expected_footer = try transcriptFooter(&footer_buffer, state.frame, digest);
            if (!std.mem.eql(u8, line, expected_footer)) return error.TranscriptResultMismatch;
            if (try reader.takeDelimiter('\n') != null) return error.TrailingTranscriptData;
            if (paths.image) |output| {
                if (digest == null) return error.UnsupportedDisplayMode;
                try screenshot.write(init.io, init.gpa, output, &pixels, .exclusive);
            }
            var stdout_buffer: [256]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            try stdout.interface.print("ok {d}\n", .{state.frame});
            return stdout.interface.flush();
        }
        switch (parse(line) catch return error.InvalidTranscriptCommand) {
            .control => |control| try state.apply(arena, control),
            .screen, .quit => return error.InvalidTranscriptCommand,
        }
    }
    return error.IncompleteTranscript;
}

const State = struct {
    machine: *zaza.Emulator,
    frame: u64 = 0,
    checkpoint: ?*Slot = null,

    const Slot = struct { machine: zaza.Emulator.Checkpoint, frame: u64 };

    fn apply(self: *State, arena: std.mem.Allocator, control: Control) !void {
        switch (control) {
            .checkpoint => {
                const slot = self.checkpoint orelse try arena.create(Slot);
                self.machine.checkpoint(&slot.machine);
                slot.frame = self.frame;
                self.checkpoint = slot;
            },
            .restore => {
                const slot = self.checkpoint orelse return error.NoCheckpoint;
                self.machine.restore(&slot.machine);
                self.frame = slot.frame;
            },
            .step => |step| for (0..step.frames) |_| {
                try self.machine.runFrame(step.buttons);
                self.frame += 1;
            },
        }
    }
};

const Control = union(enum) {
    checkpoint,
    restore,
    step: struct { frames: u32, buttons: input.Buttons },
};

const Command = union(enum) {
    quit,
    control: Control,
    screen: []const u8,
};

fn replyError(writer: *std.Io.Writer, err: anyerror) !void {
    try writer.print("error {s}\n", .{@errorName(err)});
    try writer.flush();
}

fn hash(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    Blake3.hash(bytes, &digest, .{});
    return digest;
}

fn transcriptHeader(
    buffer: []u8,
    rom: []const u8,
    options: zaza.Options,
    machine: *zaza.Emulator,
) ![]const u8 {
    const save = machine.saveMemory();
    return std.fmt.bufPrint(buffer, "start {s} {s} {s} {s} {s}", .{
        @tagName(options.boot),
        &std.fmt.bytesToHex(hash(rom), .lower),
        &std.fmt.bytesToHex(hash(options.bios), .lower),
        @tagName(save.kind),
        &std.fmt.bytesToHex(hash(save.bytes()), .lower),
    });
}

fn transcriptFooter(buffer: []u8, frame: u64, digest: ?Digest) ![]const u8 {
    if (digest) |value| {
        return std.fmt.bufPrint(buffer, "end {d} {s}", .{
            frame, &std.fmt.bytesToHex(value, .lower),
        });
    }
    return std.fmt.bufPrint(buffer, "end {d} unavailable", .{frame});
}

fn frameDigest(machine: *const zaza.Emulator, pixels: *video.Frame) ?Digest {
    machine.snapshotFrame(pixels) catch return null;
    var hasher = Blake3.init(.{});
    for (pixels) |*row| {
        var rgb: [video.width * 3]u8 = undefined;
        for (row, 0..) |pixel, index| {
            rgb[index * 3 ..][0..3].* = .{ pixel.red, pixel.green, pixel.blue };
        }
        hasher.update(&rgb);
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn parse(line: []const u8) !Command {
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    const verb = words.next() orelse return error.EmptyCommand;
    if (std.mem.eql(u8, verb, "quit") and words.next() == null) return .quit;
    if (std.mem.eql(u8, verb, "checkpoint") and words.next() == null) return .{ .control = .checkpoint };
    if (std.mem.eql(u8, verb, "restore") and words.next() == null) return .{ .control = .restore };
    if (std.mem.eql(u8, verb, "screen")) {
        const path = std.mem.trim(u8, words.rest(), " \t\r");
        if (path.len == 0) return error.MissingOutputPath;
        return .{ .screen = path };
    }
    if (std.mem.eql(u8, verb, "step")) {
        const count = words.next() orelse return error.MissingFrameCount;
        const frames = try std.fmt.parseInt(u32, count, 10);
        if (frames == 0) return error.InvalidFrameCount;
        const buttons = try input.parseButtons(&words);
        return .{ .control = .{ .step = .{ .frames = frames, .buttons = buttons } } };
    }
    return error.UnknownCommand;
}
