const std = @import("std");
const Registers = @This();

// Storage for display configuration beyond DISPCNT/DISPSTAT/VCOUNT.
// Raster effects and register read open-bus behavior are not implemented.
values: [0x28]u16 = @splat(0),

pub fn contains(address: u32) bool {
    return address >= 0x0400_0008 and address < 0x0400_0058;
}

pub fn write(self: *Registers, address: u32, value: u16) void {
    std.debug.assert(contains(address));
    std.debug.assert(address & 1 == 0);
    const offset = address - 0x0400_0008;
    const mask: u16 = switch (address) {
        0x0400_0010...0x0400_001E => 0x01FF,
        0x0400_002A, 0x0400_002E, 0x0400_003A, 0x0400_003E => 0x0FFF,
        0x0400_0048, 0x0400_004A => 0x3F3F,
        0x0400_004E, 0x0400_0056 => 0,
        0x0400_0050 => 0x3FFF,
        0x0400_0052 => 0x1F1F,
        0x0400_0054 => 0x001F,
        else => 0xFFFF,
    };
    self.values[offset / 2] = value & mask;
}

test "display configuration masks scroll affine and blend reserved bits" {
    // Check distinct register groups used by the BIOS display reset loop.
    var registers: Registers = .{};
    registers.write(0x0400_0010, 0xFFFF);
    registers.write(0x0400_002A, 0xFFFF);
    registers.write(0x0400_0052, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x01FF), registers.values[4]);
    try std.testing.expectEqual(@as(u16, 0x0FFF), registers.values[17]);
    try std.testing.expectEqual(@as(u16, 0x1F1F), registers.values[37]);
}
