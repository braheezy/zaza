const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();
const video = @import("video.zig");

cpu: Cpu,
bus: Bus,

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
