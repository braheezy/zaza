const std = @import("std");

pub const width: usize = 240;
pub const height: usize = 160;
pub const Rgb = struct { red: u8, green: u8, blue: u8 };
pub const Frame = [height][width]Rgb;
pub const bitmap_size_bytes = width * height * @sizeOf(u16);
// Decode the raw bitmap, not the timed or composited LCD output.
pub fn decodeMode3(vram: *const [bitmap_size_bytes]u8, frame: *Frame) void {
    for (frame, 0..) |*row, y| {
        for (row, 0..) |*pixel, x| {
            const offset = (y * width + x) * @sizeOf(u16);
            const color = std.mem.readInt(u16, vram[offset..][0..2], .little);
            pixel.* = decodeColor(color);
        }
    }
}

pub fn swapGreen(row: *[width]Rgb) void {
    for (0..width / 2) |pair| {
        std.mem.swap(u8, &row[pair * 2].green, &row[pair * 2 + 1].green);
    }
}

pub fn decodeColor(color: u16) Rgb {
    return .{
        .red = expandChannel(@truncate(color)),
        .green = expandChannel(@truncate(color >> 5)),
        .blue = expandChannel(@truncate(color >> 10)),
    };
}

fn expandChannel(channel: u5) u8 {
    const value: u8 = channel;
    // Repeat the high bits so full intensity maps from 31 to 255.
    return (value << 3) | (value >> 2);
}

test "Mode 3 decodes adjacent pixels and advances by one bitmap row" {
    var vram: [bitmap_size_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, vram[2..4], 0x03E0, .little);
    std.mem.writeInt(u16, vram[width * 2 ..][0..2], 0xFC00, .little);
    var frame: Frame = undefined;
    decodeMode3(&vram, &frame);
    try std.testing.expectEqual(Rgb{ .red = 0, .green = 255, .blue = 0 }, frame[0][1]);
    try std.testing.expectEqual(Rgb{ .red = 0, .green = 0, .blue = 255 }, frame[1][0]);
}
