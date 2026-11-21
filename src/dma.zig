const std = @import("std");
const DMA = @This();

pub const base: u32 = 0x0400_00B0;
pub const end: u32 = base + 4 * 12;
channels: [4]Channel = @splat(.{}),

pub const Channel = struct {
    source: u32 = 0,
    destination: u32 = 0,
    count: u16 = 0,
    control: u16 = 0,
};

pub fn contains(address: u32) bool {
    return address >= base and address < end;
}

pub fn write(self: *DMA, comptime T: type, address: u32, value: T) void {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= end);
    for (0..@sizeOf(T)) |index| {
        const offset = address - base + @as(u32, @intCast(index));
        const channel_index = offset / 12;
        const register_offset = offset % 12;
        const channel = &self.channels[channel_index];
        const byte: u8 = @truncate(value >> @intCast(index * 8));
        if (register_offset < 8) {
            const shift: u5 = @intCast((register_offset % 4) * 8);
            const target = if (register_offset < 4) &channel.source else &channel.destination;
            const mask: u32 = if (register_offset < 4)
                (if (channel_index == 0) 0x07FF_FFFF else 0x0FFF_FFFF)
            else
                (if (channel_index == 3) 0x0FFF_FFFF else 0x07FF_FFFF);
            target.* = ((target.* & ~(@as(u32, 0xFF) << shift)) |
                (@as(u32, byte) << shift)) & mask;
        } else {
            const shift: u4 = @intCast((register_offset & 1) * 8);
            const target = if (register_offset < 10) &channel.count else &channel.control;
            // Enabling DMA needs scheduling, bus arbitration and transfer timing.
            if (register_offset == 11 and byte & 0x80 != 0) {
                @panic("DMA transfers are not modeled");
            }
            const mask: u16 = if (register_offset < 10)
                (if (channel_index == 3) 0xFFFF else 0x3FFF)
            else
                (if (channel_index == 3) 0xFFE0 else 0xF7E0);
            target.* = ((target.* & ~(@as(u16, 0xFF) << shift)) |
                (@as(u16, byte) << shift)) & mask;
        }
    }
}

pub fn read(self: *const DMA, comptime T: type, address: u32) T {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= end);
    var result: T = 0;
    for (0..@sizeOf(T)) |index| {
        const offset = address - base + @as(u32, @intCast(index));
        const register_offset = offset % 12;
        if (register_offset < 8) @panic("DMA write-only address register read needs open bus");
        // Count reads return zero; only the control halfword is readable.
        if (register_offset >= 10) {
            const control = self.channels[offset / 12].control;
            const byte: u8 = @truncate(control >> @intCast((register_offset & 1) * 8));
            result |= @as(T, byte) << @intCast(index * 8);
        }
    }
    return result;
}

test "DMA register widths preserve channel masks and neighboring bytes" {
    // Cover all four channels, including DMA3's wider addresses and count.
    var dma: DMA = .{};
    for (0..4) |index| {
        const address = base + @as(u32, @intCast(index * 12));
        dma.write(u32, address, 0xFFFF_FFFF);
        dma.write(u32, address + 4, 0xFFFF_FFFF);
        dma.write(u32, address + 8, 0x7FFF_FFFF);
        try std.testing.expectEqual(@as(u32, if (index == 0) 0x07FF_FFFF else 0x0FFF_FFFF), dma.channels[index].source);
        try std.testing.expectEqual(@as(u32, if (index == 3) 0x0FFF_FFFF else 0x07FF_FFFF), dma.channels[index].destination);
        try std.testing.expectEqual(@as(u16, if (index == 3) 0xFFFF else 0x3FFF), dma.channels[index].count);
        try std.testing.expectEqual(@as(u32, if (index == 3) 0x7FE0_0000 else 0x77E0_0000), dma.read(u32, address + 8));
        dma.write(u8, address + 1, 0x12);
        try std.testing.expectEqual(@as(u16, 0x12FF), @as(u16, @truncate(dma.channels[index].source)));
    }
}
