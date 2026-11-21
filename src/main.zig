pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = (try init.minimal.args.toSlice(arena))[1..];
    const with_bios = args.len >= 2 and std.mem.eql(u8, args[0], "--bios");
    const run_args = if (with_bios) args[2..] else args;
    const bios = if (with_bios) try loadBios(init.io, arena, args[1]) else bundled_bios;
    if (run_args.len > 1 and std.mem.eql(u8, run_args[0], "replay")) {
        return replayInput(init.io, arena, bios, run_args[1..]);
    }

    const run: struct { rom: []const u8, steps: usize, output: []const u8 } = switch (run_args.len) {
        1 => .{ .rom = &mode3_demo_rom, .steps = mode3_demo_steps, .output = run_args[0] },
        3 => blk: {
            const steps = try std.fmt.parseInt(usize, run_args[1], 10);
            if (steps == 0) return error.InvalidStepCount;
            const rom = try loadRom(init.io, arena, run_args[0]);
            break :blk .{ .rom = rom, .steps = steps, .output = run_args[2] };
        },
        else => {
            std.debug.print(
                "Usage: zaza <output.bmp>\n" ++
                    "       zaza [--bios <bios.bin>] <input.gba> <steps> <output.bmp>\n" ++
                    "       zaza [--bios <bios.bin>] replay <input.gba> <frames> <output.bmp> " ++
                    "(--input <script> | --input-file <path>)\n",
                .{},
            );
            return error.InvalidArguments;
        },
    };

    var frame: video.Frame = undefined;
    try captureBitmap(run.rom, bios, run.steps, &frame);

    try writeBitmap(init.io, run.output, &frame);
}

fn loadBios(io: std.Io, arena: std.mem.Allocator, path: []const u8) !*const [Bus.bios_size_bytes]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(Bus.bios_size_bytes + 1),
    );
    if (bytes.len != Bus.bios_size_bytes) return error.InvalidBiosSize;
    return bytes[0..Bus.bios_size_bytes];
}

fn writeBitmap(io: std.Io, path: []const u8, frame: *const video.Frame) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try bmp.write(&file_writer.interface, frame);
    try file_writer.interface.flush();
}

fn replayInput(
    io: std.Io,
    arena: std.mem.Allocator,
    bios: *const [Bus.bios_size_bytes]u8,
    args: []const [:0]const u8,
) !void {
    if (args.len != 5) return error.InvalidReplayArguments;
    const frames = try std.fmt.parseInt(u32, args[1], 10);
    if (frames == 0) return error.InvalidFrameCount;
    const script = if (std.mem.eql(u8, args[3], "--input"))
        args[4]
    else if (std.mem.eql(u8, args[3], "--input-file"))
        try std.Io.Dir.cwd().readFileAlloc(io, args[4], arena, .limited(1024 * 1024))
    else
        return error.InvalidReplayArguments;
    const changes = try input.parseScript(arena, script);
    if (changes.len != 0 and changes[changes.len - 1].frame >= frames) {
        return error.InputFrameOutsideReplay;
    }

    const rom = try loadRom(io, arena, args[0]);
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(rom, bios);
    var replay: input.Replay = .{ .remaining = changes };
    for (0..frames) |index| {
        machine.runFrame(replay.buttonsForFrame(@intCast(index))) catch |err| {
            std.log.err("replay stopped in frame {d} at 0x{x:0>8}", .{
                index, machine.cpu.instruction_address,
            });
            return err;
        };
    }
    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try writeBitmap(io, args[2], &frame);
}

pub fn loadRom(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024 + 1));
    if (rom.len < 8) return error.RomTooShort;
    if (rom.len > 32 * 1024 * 1024) return error.RomTooLarge;
    return rom;
}

pub fn captureBitmap(
    rom: []const u8,
    bios: *const [Bus.bios_size_bytes]u8,
    steps: usize,
    frame: *video.Frame,
) !void {
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(rom, bios);
    for (0..steps) |step| {
        const address = machine.cpu.instruction_address;
        machine.stepTimed() catch |err| {
            std.debug.print("CPU stopped after {d} steps at 0x{x:0>8}\n", .{ step, address });
            return err;
        };
    }
    try machine.snapshotBitmap(frame);
}

const std = @import("std");
const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @import("machine.zig");
const video = @import("video.zig");
const bmp = @import("bmp.zig");
const input = @import("input.zig");

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

pub const bundled_bios = @embedFile("emibios");
comptime {
    @setEvalBranchQuota(2_000_000);
    if (bundled_bios.len != Bus.bios_size_bytes) @compileError("Invalid bundled BIOS size");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bundled_bios, &digest, .{});
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(&expected_buffer, "95e6c8a6c236ed8e2629bdb60bc75791434c4f08ca69ad2305e30ca3f3c29d1b") catch unreachable;
    if (!std.mem.eql(u8, &digest, expected)) @compileError("Bundled BIOS checksum mismatch");
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
