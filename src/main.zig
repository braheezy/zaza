pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const run: struct { rom: []const u8, steps: usize, output: []const u8 } = switch (args.len) {
        2 => .{ .rom = &mode3_demo_rom, .steps = mode3_demo_steps, .output = args[1] },
        4 => blk: {
            const steps = try std.fmt.parseInt(usize, args[2], 10);
            if (steps == 0) return error.InvalidStepCount;
            const rom = try std.Io.Dir.cwd().readFileAlloc(
                init.io,
                args[1],
                arena,
                .limited(32 * 1024 * 1024 + 1),
            );
            if (rom.len < 8) return error.RomTooShort;
            break :blk .{ .rom = rom, .steps = steps, .output = args[3] };
        },
        else => {
            std.debug.print("Usage: zaza [<input.gba> <steps>] <output.bmp>\n", .{});
            return error.InvalidArguments;
        },
    };

    var machine: Machine = undefined;
    machine.initCartridge(run.rom);
    for (0..run.steps) |step| {
        const address = machine.cpu.instruction_address;
        machine.step() catch |err| {
            std.debug.print("CPU stopped after {d} steps at 0x{x:0>8}\n", .{ step, address });
            return err;
        };
    }
    var frame: video.Frame = undefined;
    try machine.snapshotMode3(&frame);

    const file = try std.Io.Dir.cwd().createFile(init.io, run.output, .{ .exclusive = true });
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(init.io, &buffer);
    try bmp.write(&file_writer.interface, &frame);
    try file_writer.interface.flush();
}

const std = @import("std");
const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @import("machine.zig");
const video = @import("video.zig");
const bmp = @import("bmp.zig");

const mode3_demo_rom = [_]u8{
    0x03, 0x00, 0xA0, 0xE3, // MOV r0, #3
    0x01, 0x13, 0xA0, 0xE3, // MOV r1, #0x04000000
    0xB0, 0x00, 0xC1, 0xE1, // STRH r0, [r1] (DISPCNT)
    0x1F, 0x00, 0xA0, 0xE3, // MOV r0, #0x001F
    0x06, 0x14, 0xA0, 0xE3, // MOV r1, #0x06000000
    0xF0, 0x20, 0xA0, 0xE3, // MOV r2, #240
    0xB2, 0x00, 0xC1, 0xE0, // loop: STRH r0, [r1], #2
    0x01, 0x20, 0x52, 0xE2, // SUBS r2, r2, #1
    0xFC, 0xFF, 0xFF, 0x1A, // BNE loop
    0x00, 0x00, 0x00, 0x00, // Pipeline lookahead only.
    0x00, 0x00, 0x00, 0x00,
};
const mode3_demo_steps = 6 + 3 * video.width;

test {
    _ = bmp;
}

test "ARM pipeline refills from cartridge ROM bytes" {
    const rom = [_]u8{
        0x2A, 0x00, 0xA0, 0xE3, // MOV r0, #42
        0x00, 0x10, 0xA0, 0xE3, // MOV r1, #0
    };
    const bus: Bus = .{ .rom = &rom };
    var cpu: Cpu = .{ .instruction_address = Bus.rom_base };

    cpu.refillArmPipeline(&bus);

    try std.testing.expectEqual([2]u32{ 0xE3A0_002A, 0xE3A0_1000 }, cpu.pipeline.?);
}

test "ARM program executes from ROM and stores a word in internal RAM" {
    const rom = [_]u8{
        0x2A, 0x00, 0xA0, 0xE3, // MOV r0, #42
        0x03, 0x14, 0xA0, 0xE3, // MOV r1, #0x03000000
        0x00, 0x00, 0x81, 0xE5, // STR r0, [r1]
        // Pipeline lookahead fetches these bytes, but the test never executes them.
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    for (0..3) |_| try machine.step();

    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, machine.bus.iwram[0..4]);
    try std.testing.expectEqual(@as(u32, 42), machine.bus.readData(u32, Bus.iwram_base));
}

test "ARM program writes the memory-mapped display control register" {
    const rom = [_]u8{
        0x03, 0x00, 0xA0, 0xE3, // MOV r0, #3
        0x01, 0x13, 0xA0, 0xE3, // MOV r1, #0x04000000
        0xB0, 0x00, 0xC1, 0xE1, // STRH r0, [r1]
        // Pipeline lookahead only.
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    for (0..3) |_| try machine.step();

    try std.testing.expectEqual(@as(u16, 3), machine.bus.dispcnt);
    try std.testing.expectEqual(@as(u16, 3), machine.bus.readData(u16, Bus.dispcnt_address));
}

test "ARM program selects Mode 3 and writes a red row" {
    var machine: Machine = undefined;
    machine.initCartridge(&mode3_demo_rom);
    var frame: video.Frame = undefined;
    try std.testing.expectError(error.NotMode3, machine.snapshotMode3(&frame));
    for (0..mode3_demo_steps) |_| try machine.step();

    try std.testing.expectEqualSlices(u8, &.{ 0x1F, 0x00 }, machine.bus.vram[0..2]);
    try std.testing.expectEqual(@as(u16, 0x001F), machine.bus.readData(u16, Bus.vram_base));
    try machine.snapshotMode3(&frame);
    for (frame[0]) |pixel| {
        try std.testing.expectEqual(video.Rgb{ .red = 255, .green = 0, .blue = 0 }, pixel);
    }
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 0, .blue = 0 }, frame[1][0]);
}
