pub fn main() void {
    _ = @sizeOf(Cpu);
}

const std = @import("std");
const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");

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
    var bus: Bus = .{ .rom = &rom };
    var cpu: Cpu = .{ .instruction_address = Bus.rom_base };
    cpu.refillArmPipeline(&bus);
    for (0..3) |_| try cpu.step(&bus);

    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, bus.iwram[0..4]);
    try std.testing.expectEqual(@as(u32, 42), bus.readData(u32, Bus.iwram_base));
}
