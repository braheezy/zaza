const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();
const video = @import("video.zig");
const timing = @import("timing.zig");
const input = @import("input.zig");

cpu: Cpu,
bus: Bus,
elapsed_cycles: u64 = 0,

const vblank_start = timing.vblank_start;

// Start directly at the cartridge entry point without running the BIOS.
pub fn initCartridge(self: *Machine, rom: []const u8) void {
    self.* = .{
        .cpu = .{ .instruction_address = Bus.rom_base },
        .bus = .{ .rom = rom },
    };
    self.cpu.refillArmPipeline(&self.bus);
}

pub fn initCartridgeWithBios(
    self: *Machine,
    rom: []const u8,
    bios: *const [Bus.bios_size_bytes]u8,
) void {
    self.initCartridge(rom);
    self.bus.bios = bios;
    // Fast boot skips the BIOS routine that initializes the banked stacks.
    self.cpu.cpsr = 0x1F; // System mode, ARM state.
    self.cpu.registers[13] = 0x0300_7F00;
    self.cpu.banked.irq[0] = 0x0300_7FA0;
    self.cpu.banked.supervisor[0] = 0x0300_7FE0;
}

pub fn step(self: *Machine) !void {
    // Sample IRQ before executing the next queued instruction.
    if (self.bus.irqLine() and !self.cpu.irqMasked()) {
        if (self.bus.bios == null) return error.IrqNeedsBios;
        self.cpu.enterIrq(&self.bus);
        return;
    }
    // BIOS data visibility depends on the executing instruction, not lookahead fetches.
    self.bus.executing_bios = self.cpu.instruction_address < Bus.bios_size_bytes;
    defer self.bus.executing_bios = false;
    try self.cpu.step(&self.bus);
}

/// Advance the clock for one supported CPU instruction or IRQ entry.
/// Cartridge prefetch hits and contention are not included in the bus costs.
pub fn stepTimed(self: *Machine) !void {
    const bus_cycles_before = self.bus.bus_cycles;
    const internal_cycles_before = self.cpu.internal_cycles;
    try self.step();
    const bus_cycles = self.bus.bus_cycles - bus_cycles_before;
    const internal_cycles = self.cpu.internal_cycles - internal_cycles_before;
    self.advanceClock(bus_cycles + internal_cycles);
}

/// Apply a full keypad snapshot and run to the next VBlank for frontends and replay.
pub fn runFrame(self: *Machine, buttons: input.Buttons) !void {
    self.bus.setPressedButtons(buttons);
    // Every supported instruction advances at least one cycle.
    try self.runToVBlank(timing.cycles_per_frame);
}

/// Stop on the first instruction boundary at or after the next VBlank edge.
pub fn runToVBlank(self: *Machine, instruction_budget: usize) !void {
    const phase = self.elapsed_cycles % timing.cycles_per_frame;
    const target = self.elapsed_cycles + timing.cyclesUntil(
        phase,
        timing.vblank_start,
        timing.cycles_per_frame,
    );
    for (0..instruction_budget) |_| {
        try self.stepTimed();
        if (self.elapsed_cycles >= target) return;
    }
    return error.InstructionBudgetExceeded;
}

fn advanceClock(self: *Machine, cycles: u64) void {
    const old_phase = self.elapsed_cycles % timing.cycles_per_frame;
    self.elapsed_cycles += cycles;
    self.bus.advanceDevices(old_phase, cycles);
}

test "timed cartridge branch loop raises VBlank IF even with IRQ delivery masked" {
    const std = @import("std");
    const rom = [_]u8{
        0xFE, 0xFF, 0xFF, 0xEA, // B to self (20 cycles per iteration).
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    // Seed hardware state directly so inspection does not interrupt the Game Pak burst.
    machine.bus.dispstat |= 1 << 3;
    for (0..vblank_start / 20 - 1) |_| try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start - 20), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 9), machine.bus.dispstat);
    try std.testing.expectEqual(@as(u16, 1), machine.bus.irq_flags);
    try std.testing.expect(!machine.bus.irqLine());

    machine.bus.writeData(u16, Bus.if_address, 1);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
}

test "timed ROM fetches use WAITCNT even with prefetch enabled" {
    const std = @import("std");
    const rom = [_]u8{
        0xFE, 0xFF, 0xFF, 0xEA, // B to self.
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 20), machine.elapsed_cycles);

    machine.bus.writeData(u16, Bus.waitcnt_address, 0x0018);
    try machine.stepTimed();
    // The register write breaks the sequence, then the branch breaks it again.
    try std.testing.expectEqual(@as(u64, 20 + 5 + 5 + 4), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 34 + 4 + 5 + 4), machine.elapsed_cycles);

    machine.bus.writeData(u16, Bus.waitcnt_address, 0x4018);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 47 + 5 + 5 + 4), machine.elapsed_cycles);
}

test "timed IWRAM store charges one data cycle and breaks the next ROM fetch" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0x81, 0xE5, // STR r0, [r1]
        0x01, 0x20, 0xA0, 0xE3, // MOV r2, #1
        0x02, 0x20, 0xA0, 0xE3, // MOV r2, #2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = 42;
    machine.cpu.registers[1] = Bus.iwram_base;

    try machine.stepTimed();
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, machine.bus.iwram[0..4]);
    try std.testing.expectEqual(@as(u64, 0), machine.cpu.internal_cycles);
    try std.testing.expectEqual(@as(u64, 6 + 1), machine.elapsed_cycles);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 7 + 8), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 15 + 6), machine.elapsed_cycles);
}

test "timed IWRAM load charges a data cycle and an internal cycle" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0x91, 0xE5, // LDR r0, [r1]
        0x01, 0x20, 0xA0, 0xE3, // MOV r2, #1
        0x02, 0x20, 0xA0, 0xE3, // MOV r2, #2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.iwram_base;
    // Seed the bytes without issuing a bus transaction before the load.
    std.mem.writeInt(u32, machine.bus.iwram[0..4], 42, .little);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[0]);
    try std.testing.expectEqual(@as(u64, 1), machine.bus.iwram_data_cycles);
    try std.testing.expectEqual(@as(u64, 1), machine.cpu.internal_cycles);
    try std.testing.expectEqual(@as(u64, 6 + 1 + 1), machine.elapsed_cycles);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 8 + 8), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 16 + 6), machine.elapsed_cycles);
}

test "timed Game Pak data load pays the nonsequential data access cost" {
    const std = @import("std");
    const rom = [_]u8{ 0x00, 0x00, 0x91, 0xE5, 0, 0, 0, 0, 0, 0, 0, 0 }; // LDR r0, [r1]
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.rom_base;
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0xE591_0000), machine.cpu.registers[0]);
    try std.testing.expectEqual(@as(u64, 6 + 8 + 1), machine.elapsed_cycles);
}

test "cartridge SWI executes a BIOS handler that reads a BIOS literal" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x00, 0x00, 0xEF, // SWI
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[8..12], 0xE59F_0000, .little); // LDR r0, [pc]
        std.mem.writeInt(u32, bytes[16..20], 0x1234_5678, .little);
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, &bios);
    try std.testing.expectEqual(@as(u32, 0x0300_7F00), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 8), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u32, 0x0300_7FE0), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0x1234_5678), machine.cpu.readRegister(0));
}

test "Machine takes a pending IRQ at a Thumb instruction boundary" {
    const std = @import("std");
    const rom = [_]u8{
        0x10, 0xFF, 0x2F, 0xE1, // BX r0
        0x2A, 0x21, 0x00, 0x00, // MOV r1, #42, then Thumb lookahead.
        0x00, 0x00, 0x00, 0x00, // ARM lookahead.
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0x18..0x1C], 0xE1A0_0000, .little);
        std.mem.writeInt(u32, bytes[0x1C..0x20], 0xE1A0_1001, .little);
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = Bus.rom_base + 5;
    machine.bus.requestInterrupt(1);
    machine.bus.writeData(u16, Bus.ie_address, 1);
    machine.bus.writeData(u16, Bus.ime_address, 1);

    // The initial CPU IRQ mask lets BX execute despite the asserted line.
    try machine.step();
    try std.testing.expectEqual(Bus.rom_base + 4, machine.cpu.instruction_address);
    machine.cpu.cpsr &= ~@as(u32, 1 << 7);
    const interrupted_status = machine.cpu.cpsr;
    try std.testing.expectError(error.IrqNeedsBios, machine.step());
    try std.testing.expectEqual(interrupted_status, machine.cpu.cpsr);

    machine.bus.bios = &bios;
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0), machine.cpu.registers[1]);
    try std.testing.expectEqual(@as(u32, 0x18), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u32, 0xD2), machine.cpu.cpsr);
    try std.testing.expectEqual(interrupted_status, machine.cpu.spsr[3]);
    try std.testing.expectEqual(Bus.rom_base + 8, machine.cpu.banked.irq[1]);
    try std.testing.expectEqual([2]u32{ 0xE1A0_0000, 0xE1A0_1001 }, machine.cpu.pipeline.?);
    try std.testing.expect(machine.bus.irqLine());
}

pub fn snapshotMode3(self: *const Machine, frame: *video.Frame) error{NotMode3}!void {
    if (self.bus.dispcnt & 0b111 != 3) return error.NotMode3;
    video.decodeMode3(self.bus.vram[0..video.bitmap_size_bytes], frame);
}

/// Capture the selected bitmap using the current display registers and memory.
pub fn snapshotBitmap(self: *const Machine, frame: *video.Frame) error{UnsupportedDisplayMode}!void {
    switch (self.bus.dispcnt & 7) {
        3 => video.decodeMode3(self.bus.vram[0..video.bitmap_size_bytes], frame),
        4 => self.snapshotMode4(frame),
        else => return error.UnsupportedDisplayMode,
    }
}

fn snapshotMode4(self: *const Machine, frame: *video.Frame) void {
    const registers = &self.bus.display_registers;
    const page = self.bus.dispcnt & (1 << 4) != 0;
    const offset: usize = if (page) video.mode4_page_stride_bytes else 0;
    const mosaic_enabled = registers.stored(0x0400_000C) & (1 << 6) != 0;
    const mosaic = registers.stored(0x0400_004C);
    video.renderMode4(
        self.bus.vram[offset..][0..video.mode4_bitmap_size_bytes],
        self.bus.palette[0..video.background_palette_size_bytes],
        .{
            .enabled = self.bus.dispcnt & (1 << 10) != 0,
            .forced_blank = self.bus.dispcnt & (1 << 7) != 0,
            .green_swap = self.bus.greenswap != 0,
            .dx = @bitCast(registers.stored(0x0400_0020)),
            .dmx = @bitCast(registers.stored(0x0400_0022)),
            .dy = @bitCast(registers.stored(0x0400_0024)),
            .dmy = @bitCast(registers.stored(0x0400_0026)),
            .origin_x = registers.affineReference(0x0400_0028),
            .origin_y = registers.affineReference(0x0400_002C),
            .mosaic_width = if (mosaic_enabled) 1 + @as(u5, @as(u4, @truncate(mosaic))) else 1,
            .mosaic_height = if (mosaic_enabled) 1 + @as(u5, @as(u4, @truncate(mosaic >> 4))) else 1,
        },
        frame,
    );
}

test "machine clock routes timer overflow IRQs while delivery is masked" {
    const std = @import("std");
    // Keep the CPU idle to isolate shared-clock device advancement and IRQ latching.
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    machine.bus.writeData(u32, 0x0400_0100, 0x00C0_FFFE);
    machine.advanceClock(1);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
    machine.advanceClock(1);
    try std.testing.expectEqual(@as(u16, 8), machine.bus.irq_flags);
    try std.testing.expect(!machine.bus.irqLine());
    try std.testing.expectEqual(@as(u16, 0xFFFE), machine.bus.readData(u16, 0x0400_0100));
}

test "a Thumb VCOUNT polling loop writes palette RAM once on each VBlank" {
    const std = @import("std");
    const rom = [_]u8{
        0x14, 0xFF, 0x2F, 0xE1, // BX r4
        0,    0,    0,    0,
        0,    0,    0,    0,
        0x08, 0x78, // wait_draw: LDRB r0, [r1]
        0xA0, 0x28, // CMP r0, #160
        0xFC, 0xD2, // BHS wait_draw
        0x08, 0x78, // wait_blank: LDRB r0, [r1]
        0xA0, 0x28, // CMP r0, #160
        0xFC, 0xD3, // BLO wait_blank
        0x01, 0x33, // ADDS r3, #1
        0x13, 0x80, // STRH r3, [r2]
        0xF6, 0xE7, // B wait_draw
        0,    0,
        0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.vcount_address;
    machine.cpu.registers[2] = Bus.palette_base;
    machine.cpu.registers[4] = Bus.rom_base + 13;
    machine.bus.writeData(u16, Bus.waitcnt_address, 0x4317);

    for (0..3) |frame| {
        try machine.runToVBlank(timing.cycles_per_frame);
        try std.testing.expectEqual(@as(u8, 160), machine.bus.vcount);
        const edge = timing.vblank_start + frame * timing.cycles_per_frame;
        try std.testing.expect(machine.elapsed_cycles >= edge);
        try std.testing.expect(machine.elapsed_cycles < edge + 32);
        // Let the polling branch observe line 160 and execute its palette store.
        for (0..16) |_| try machine.stepTimed();
        const color = std.mem.readInt(u16, machine.bus.palette[0..2], .little);
        try std.testing.expectEqual(@as(u16, @intCast(frame + 1)), color);
    }
}

test "Mode 4 selects the front and back pages and uses the live background palette" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const bus = &machine.bus;
    bus.writeData(u16, 0x0400_0020, 0x0100); // BG2PA
    bus.writeData(u16, 0x0400_0026, 0x0100); // BG2PD
    bus.writeData(u16, Bus.palette_base, 0x7C00);
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 510, 0x03E0);
    bus.writeData(u16, Bus.palette_base + 512, 0x7FFF);
    bus.writeData(u16, Bus.vram_base, 0x0001);
    bus.writeData(u16, Bus.vram_base + 0xA000, 0xFF00);
    bus.writeData(u16, Bus.vram_base + 0xA000 + 0x95FE, 0xFF00);

    const red: video.Rgb = .{ .red = 255, .green = 0, .blue = 0 };
    const green: video.Rgb = .{ .red = 0, .green = 255, .blue = 0 };
    const blue: video.Rgb = .{ .red = 0, .green = 0, .blue = 255 };
    const white: video.Rgb = .{ .red = 255, .green = 255, .blue = 255 };
    var frame: video.Frame = undefined;
    try std.testing.expectError(error.UnsupportedDisplayMode, machine.snapshotBitmap(&frame));
    bus.writeData(u16, Bus.dispcnt_address, 0x0404);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(red, frame[0][0]);
    try std.testing.expectEqual(blue, frame[0][1]);
    bus.writeData(u8, Bus.dispcnt_address, 0x14);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(blue, frame[0][0]);
    try std.testing.expectEqual(green, frame[0][1]);
    try std.testing.expectEqual(green, frame[video.height - 1][video.width - 1]);
    bus.writeData(u16, Bus.palette_base + 510, 0x801F);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(red, frame[0][1]);
    bus.writeData(u16, Bus.palette_base + 510, 0x03E0);
    bus.writeData(u16, Bus.dispcnt_address + 2, 1);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 255, .blue = 255 }, frame[0][0]);
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 0, .blue = 0 }, frame[0][1]);
    bus.writeData(u16, Bus.dispcnt_address + 2, 0);
    bus.writeData(u16, Bus.dispcnt_address, 0x0014);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(blue, frame[0][1]);
    bus.writeData(u16, Bus.dispcnt_address, 0x0494);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(white, frame[0][0]);
    try std.testing.expectEqual(white, frame[video.height - 1][video.width - 1]);
}

test "Mode 4 samples signed BG2 coordinates with mosaic and backdrop clipping" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const bus = &machine.bus;
    bus.writeData(u16, Bus.dispcnt_address, 0x0404);
    bus.writeData(u16, 0x0400_0020, 0x0100);
    bus.writeData(u16, 0x0400_0026, 0x0100);
    bus.writeData(u32, 0x0400_0028, 0x0FFF_FF00); // BG2X = -1.0.
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 4, 0x03E0);
    bus.writeData(u16, Bus.palette_base + 6, 0x7C00);
    bus.writeData(u16, Bus.vram_base, 0x0201);
    bus.writeData(u16, Bus.vram_base + video.width, 0x0303);

    const red: video.Rgb = .{ .red = 255, .green = 0, .blue = 0 };
    const green: video.Rgb = .{ .red = 0, .green = 255, .blue = 0 };
    const blue: video.Rgb = .{ .red = 0, .green = 0, .blue = 255 };
    const black: video.Rgb = .{ .red = 0, .green = 0, .blue = 0 };
    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(black, frame[0][0]);
    try std.testing.expectEqual(red, frame[0][1]);
    try std.testing.expectEqual(green, frame[0][2]);
    try std.testing.expectEqual(blue, frame[1][1]);

    bus.writeData(u16, 0x0400_000C, 1 << 6); // Enable BG2 mosaic.
    bus.writeData(u16, 0x0400_004C, 0x0011); // 2 x 2 mosaic blocks.
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(black, frame[0][1]);
    try std.testing.expectEqual(green, frame[0][2]);
    try std.testing.expectEqual(green, frame[1][3]);
}
