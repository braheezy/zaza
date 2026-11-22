const std = @import("std");
const DebugPort = @This();

const text_address: u32 = 0x04FF_F600;
const flags_address: u32 = 0x04FF_F700;
const enable_address: u32 = 0x04FF_F780;
const send_bit: u16 = 1 << 8;
const log = std.log.scoped(.gba);

enabled: bool = false,
flags: u16 = 0,
buffer: [256]u8 = @splat(0),

pub fn read(self: *const DebugPort, comptime T: type, address: u32) ?T {
    if (address >= text_address and address < flags_address) {
        const offset = address - text_address;
        return std.mem.readInt(T, self.buffer[offset..][0..@sizeOf(T)], .little);
    }
    const register: u16 = switch (address & ~@as(u32, 1)) {
        enable_address => if (self.enabled) 0x1DEA else 0,
        flags_address => self.flags,
        else => return null,
    };
    const shift: u4 = @intCast((address & 1) * 8);
    return @truncate(@as(u32, register) >> shift);
}

pub fn write(self: *DebugPort, comptime T: type, address: u32, value: T) bool {
    if (address >= text_address and address < flags_address) {
        const offset = address - text_address;
        std.mem.writeInt(T, self.buffer[offset..][0..@sizeOf(T)], value, .little);
        return true;
    }
    // The handshake and send registers are halfwords.
    switch (address & ~@as(u32, 1)) {
        enable_address => if (T != u8) {
            self.enabled = @as(u16, @truncate(value)) == 0xC0DE;
        },
        flags_address => if (T != u8 and self.enabled) {
            const flags: u16 = @truncate(value);
            self.flags = flags & ~send_bit;
            if (flags & send_bit != 0) self.send();
        },
        else => return false,
    }
    return true;
}

fn send(self: *DebugPort) void {
    const message = std.mem.sliceTo(&self.buffer, 0);
    switch (self.flags & 7) {
        // Guest errors are diagnostic output.
        0 => std.log.scoped(.gba_fatal).err("{s}", .{message}),
        1 => log.err("{s}", .{message}),
        2 => log.warn("{s}", .{message}),
        3 => log.info("{s}", .{message}),
        4 => log.debug("{s}", .{message}),
        else => {},
    }
    self.buffer = @splat(0);
}

test "mGBA debug port handshakes and accepts packed text stores" {
    var port: DebugPort = .{};
    try std.testing.expectEqual(@as(?u16, 0), port.read(u16, enable_address));
    try std.testing.expect(port.write(u16, enable_address, 0xC0DE));
    try std.testing.expectEqual(@as(?u16, 0x1DEA), port.read(u16, enable_address));
    try std.testing.expect(port.write(u32, text_address, 0x5453_4554));
    try std.testing.expectEqualStrings("TEST", std.mem.sliceTo(&port.buffer, 0));
    try std.testing.expect(port.write(u16, enable_address, 0));
    try std.testing.expectEqual(@as(?u16, 0), port.read(u16, enable_address));
}
