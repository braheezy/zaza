const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();
const video = @import("video.zig");

cpu: Cpu,
bus: Bus,
elapsed_cycles: u64 = 0,

const cycles_per_line = 1232;
const cycles_per_frame = cycles_per_line * 228;
const vblank_start = cycles_per_line * 160;
const vblank_end = cycles_per_line * 227;

// Start directly at the cartridge entry point without running the BIOS.
pub fn initCartridge(self: *Machine, rom: []const u8) void {
    self.* = .{
        .cpu = .{ .instruction_address = Bus.rom_base },
        .bus = .{ .rom = rom },
    };
    self.cpu.refillArmPipeline(&self.bus);
}

pub fn step(self: *Machine) !void {
    // Sample IRQ before executing the next queued instruction.
    if (self.bus.irqLine() and !self.cpu.irqMasked()) {
        if (self.bus.bios == null) return error.IrqNeedsBios;
        self.cpu.enterIrq(&self.bus);
        return;
    }
    try self.cpu.step(&self.bus);
}

// Use this from cartridge startup; ordinary step() does not advance the clock.
pub fn stepTimed(self: *Machine) !void {
    if (self.bus.irqLine() and !self.cpu.irqMasked()) return error.UntimedIrq;
    const instruction = (self.cpu.pipeline orelse return error.PipelineNotReady)[0];
    const address = self.cpu.instruction_address;
    if (self.cpu.cpsr & (1 << 5) != 0) return error.UntimedInstruction;
    if (!self.romContainsWord(address) or !self.romContainsWord(address +% 8)) {
        return error.UntimedInstruction;
    }

    // Plain MOV and B need no data transfers or CPU-internal cycles.
    const mov_immediate = instruction & 0xFFF0_0000 == 0xE3A0_0000 and
        instruction >> 12 & 0xF != 0xF;
    if (instruction >> 24 == 0xEA) {
        const words: i24 = @bitCast(@as(u24, @truncate(instruction)));
        const target = address +% 8 +% @as(u32, @bitCast(@as(i32, words) * 4));
        if (!self.romContainsWord(target) or !self.romContainsWord(target +% 4)) {
            return error.UntimedInstruction;
        }
    } else if (!mov_immediate) return error.UntimedInstruction;

    const fetch_cycles_before = self.bus.rom_fetch_cycles;
    try self.step();
    self.advanceClock(self.bus.rom_fetch_cycles - fetch_cycles_before);
}

fn romContainsWord(self: *const Machine, address: u32) bool {
    if (address < Bus.rom_base or address >= 0x0A00_0000) return false;
    return address - Bus.rom_base + 4 <= self.bus.rom.len;
}

fn advanceClock(self: *Machine, cycles: u64) void {
    const old_phase = self.elapsed_cycles % cycles_per_frame;
    const until_vblank = if (old_phase < vblank_start)
        vblank_start - old_phase
    else
        cycles_per_frame - old_phase + vblank_start;
    self.elapsed_cycles += cycles;
    const phase = self.elapsed_cycles % cycles_per_frame;
    self.bus.updateVBlank(phase >= vblank_start and phase < vblank_end, cycles >= until_vblank);
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
    machine.bus.writeData(u16, Bus.dispstat_address, 0b1001);
    try std.testing.expectEqual(@as(u16, 8), machine.bus.readData(u16, Bus.dispstat_address));

    for (0..vblank_start / 20 - 1) |_| try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start - 20), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.readData(u16, Bus.if_address));
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 9), machine.bus.readData(u16, Bus.dispstat_address));
    try std.testing.expectEqual(@as(u16, 1), machine.bus.readData(u16, Bus.if_address));
    try std.testing.expect(!machine.bus.irqLine());

    machine.bus.writeData(u16, Bus.if_address, 1);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u16, 0), machine.bus.readData(u16, Bus.if_address));
}

test "timed stepping rejects a data transfer before advancing the CPU or clock" {
    const std = @import("std");
    const rom = [_]u8{ 0x00, 0x00, 0x81, 0xE5, 0, 0, 0, 0, 0, 0, 0, 0 }; // STR r0, [r1]
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    try std.testing.expectError(error.UntimedInstruction, machine.stepTimed());
    try std.testing.expectEqual(Bus.rom_base, machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u64, 0), machine.elapsed_cycles);
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
