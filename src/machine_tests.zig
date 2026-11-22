const std = @import("std");
const Audio = @import("audio.zig");
const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @import("machine.zig");
const video = @import("video.zig");
const bmp = @import("bmp.zig");
const input = @import("input.zig");
const bundled_bios = @import("cartridge.zig").bundled_bios;
const demo = @import("mode3_demo.zig");

test {
    _ = @import("wav.zig");
    _ = @import("save_file.zig");
    _ = bmp;
    _ = input;
    _ = @import("timing.zig");
}

test "ARM pipeline refills from cartridge ROM bytes" {
    const rom = [_]u8{
        0x2A, 0x00, 0xA0, 0xE3, // MOV r0, #42
        0x00, 0x10, 0xA0, 0xE3, // MOV r1, #0
    };
    var bus: Bus = .{ .rom = &rom };
    var cpu: Cpu = .{ .instruction_address = Bus.rom_base };

    cpu.refillArmPipeline(&bus);

    try std.testing.expectEqual([2]u32{ 0xE3A0_002A, 0xE3A0_1000 }, cpu.pipeline.?);
}

test "ARM branch starts a fresh cartridge fetch sequence" {
    const rom = [_]u8{
        0x2A, 0x00, 0xA0, 0xE3, // MOV r0, #42
        0x01, 0x00, 0x00, 0xEA, // B to ROM offset 16
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xA0, 0xE1, // Branch target.
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    try std.testing.expectEqual(@as(u64, 8 + 6), machine.bus.rom_fetch_cycles);

    try machine.step();
    try std.testing.expectEqual(@as(u64, 14 + 6), machine.bus.rom_fetch_cycles);

    try machine.step();
    try std.testing.expectEqual(Bus.rom_base + 16, machine.cpu.instruction_address);
    // Lookahead reaches offset 12, but the redirect still starts a new sequence at 16.
    try std.testing.expectEqual(@as(u64, 20 + 6 + 8 + 6), machine.bus.rom_fetch_cycles);
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
    machine.initCartridge(&demo.rom);
    var frame: video.Frame = undefined;
    try std.testing.expectError(error.NotMode3, machine.snapshotMode3(&frame));
    for (0..demo.steps) |_| try machine.step();

    try std.testing.expectEqualSlices(u8, &.{ 0x1F, 0x00 }, machine.bus.vram[0..2]);
    try std.testing.expectEqual(@as(u16, 0x001F), machine.bus.readData(u16, Bus.vram_base));
    try machine.snapshotMode3(&frame);
    for (frame[0]) |pixel| {
        try std.testing.expectEqual(video.Rgb{ .red = 255, .green = 0, .blue = 0 }, pixel);
    }
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 0, .blue = 0 }, frame[1][0]);
}

test "bundled emibios RegisterRamReset returns to cartridge and restores System mode" {
    // A zero reset mask isolates exception return from unimplemented peripherals.
    const rom = [_]u8{
        0x00, 0x00, 0xA0, 0xE3, // MOV r0, #0
        0x00, 0x00, 0x01, 0xEF, // SWI 0x010000 (RegisterRamReset)
        0x2A, 0x40, 0xA0, 0xE3, // MOV r4, #42
        0xFE, 0xFF, 0xFF, 0xEA, // B to self
        0,    0,    0,    0,
        0,    0,    0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, bundled_bios);
    const original_status = machine.cpu.cpsr;
    const original_stack = machine.cpu.registers[13];
    var entered_bios = false;
    for (0..10_000) |_| {
        if (machine.cpu.instruction_address < Bus.bios_size_bytes) entered_bios = true;
        if (machine.cpu.instruction_address == Bus.rom_base + 12) break;
        try machine.step();
    } else return error.BiosDidNotReturn;
    try std.testing.expect(entered_bios);
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[4]);
    try std.testing.expectEqual(original_status, machine.cpu.cpsr);
    try std.testing.expectEqual(original_stack, machine.cpu.registers[13]);
}

test "bundled emibios sound reset clears mixer routing and returns to the cartridge" {
    const rom = [_]u8{
        0x40, 0x00, 0xA0, 0xE3, // MOV r0, #0x40 (reset sound).
        0x00, 0x00, 0x01, 0xEF, // SWI 0x010000 (RegisterRamReset).
        0x2A, 0x40, 0xA0, 0xE3, // MOV r4, #42.
        0xFE, 0xFF, 0xFF, 0xEA, // B to self.
        0,    0,    0,    0,
        0,    0,    0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, bundled_bios);
    machine.bus.writeData(u8, 0x0400_0084, 0x80);
    machine.bus.writeData(u32, 0x0400_0080, 0x770F_FF77);
    for (0..10_000) |_| {
        if (machine.cpu.instruction_address == Bus.rom_base + 12) break;
        try machine.step();
    } else return error.BiosDidNotReturn;
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[4]);
    // emibios leaves the Direct Sound gain bits set and clears stereo routing.
    try std.testing.expectEqual(@as(u32, 0x000E_0000), machine.bus.readData(u32, 0x0400_0080));
}

test "bundled emibios clears both palette banks and returns to the cartridge" {
    const rom = [_]u8{
        0x04, 0x00, 0xA0, 0xE3, // MOV r0, #4 (reset palette RAM).
        0x00, 0x00, 0x01, 0xEF, // SWI 0x010000 (RegisterRamReset).
        0x2A, 0x40, 0xA0, 0xE3, // MOV r4, #42.
        0xFE, 0xFF, 0xFF, 0xEA, // B to self.
        0,    0,    0,    0,
        0,    0,    0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, bundled_bios);
    @memset(&machine.bus.palette, 0xFF);
    for (0..10_000) |_| {
        if (machine.cpu.instruction_address == Bus.rom_base + 12) break;
        try machine.step();
    } else return error.BiosDidNotReturn;
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[4]);
    const cleared: @TypeOf(machine.bus.palette) = @splat(0);
    try std.testing.expectEqualSlices(u8, &cleared, &machine.bus.palette);
}

test "bundled emibios clears OAM and returns to the cartridge" {
    const rom = [_]u8{
        0x10, 0x00, 0xA0, 0xE3, // MOV r0, #0x10 (reset OAM).
        0x00, 0x00, 0x01, 0xEF, // SWI 0x010000 (RegisterRamReset).
        0x2A, 0x40, 0xA0, 0xE3, // MOV r4, #42.
        0xFE, 0xFF, 0xFF, 0xEA, // B to self.
        0,    0,    0,    0,
        0,    0,    0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, bundled_bios);
    @memset(&machine.bus.oam, 0xFF);
    for (0..10_000) |_| {
        if (machine.cpu.instruction_address == Bus.rom_base + 12) break;
        try machine.step();
    } else return error.BiosDidNotReturn;
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[4]);
    const cleared: @TypeOf(machine.bus.oam) = @splat(0);
    try std.testing.expectEqualSlices(u8, &cleared, &machine.bus.oam);
}

test "Direct Sound cartridge produces a stereo ramp across repeated DMA refills" {
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(@embedFile("direct_sound_rom"), bundled_bios);
    var pcm: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&pcm);
    var capture: Audio.Capture = .{ .writer = &writer };
    machine.bus.audio.capture = &capture;
    try machine.runFrame(0);
    try std.testing.expect(capture.failure == null);
    try std.testing.expectEqual(machine.elapsed_cycles / Audio.sample_period * 4, capture.bytes);

    const data = writer.buffered();
    var first_left: ?usize = null;
    var first_right: ?usize = null;
    for (0..data.len / 4) |i| {
        const left = std.mem.readInt(i16, data[i * 4 ..][0..2], .little);
        const right = std.mem.readInt(i16, data[i * 4 + 2 ..][0..2], .little);
        if (left != 0 and first_left == null) first_left = i;
        if (right != 0 and first_right == null) first_right = i;
        if (first_left) |start| {
            const byte: u8 = @truncate(i - start + 1);
            const signed: i8 = @bitCast(byte);
            try std.testing.expectEqual(@as(i16, signed) * 128, left);
        }
        if (first_right) |start| {
            const n = (i - start) / 2;
            const byte: u8 = 0 -% @as(u8, @truncate(n + 2));
            const signed: i8 = @bitCast(byte);
            try std.testing.expectEqual(@as(i16, signed) * 128, right);
        }
    }
    try std.testing.expect(first_left != null and first_right != null);
    try std.testing.expectEqual(first_left.? + 1, first_right.?);
}
