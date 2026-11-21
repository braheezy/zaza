const std = @import("std");

pub const width: usize = 240;
pub const height: usize = 160;
pub const Rgb = struct { red: u8, green: u8, blue: u8 };
pub const Frame = [height][width]Rgb;
pub const bitmap_size_bytes = width * height * @sizeOf(u16);
pub const mode4_bitmap_size_bytes = width * height;
pub const mode4_page_stride_bytes = 0xA000;
pub const background_palette_size_bytes = 256 * @sizeOf(u16);

pub const Mode4 = struct {
    // Reference points and matrix coefficients share eight fractional bits.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    dx: i16 = 256,
    dmx: i16 = 0,
    dy: i16 = 0,
    dmy: i16 = 256,
    mosaic_width: u5 = 1,
    mosaic_height: u5 = 1,
    enabled: bool = true,
    forced_blank: bool = false,
    green_swap: bool = false,
};

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

// Render a Mode 4 background snapshot with one set of registers for the whole frame.
pub fn renderMode4(
    bitmap: *const [mode4_bitmap_size_bytes]u8,
    palette: *const [background_palette_size_bytes]u8,
    options: Mode4,
    frame: *Frame,
) void {
    if (options.forced_blank) {
        frame.* = @splat(@splat(.{ .red = 255, .green = 255, .blue = 255 }));
        return;
    }

    var colors: [256]Rgb = undefined;
    for (&colors, 0..) |*color, index| {
        color.* = decodeColor(std.mem.readInt(u16, palette[index * 2 ..][0..2], .little));
    }
    if (!options.enabled) {
        frame.* = @splat(@splat(colors[0]));
        return;
    }

    std.debug.assert(options.mosaic_width >= 1 and options.mosaic_width <= 16);
    std.debug.assert(options.mosaic_height >= 1 and options.mosaic_height <= 16);
    for (frame, 0..) |*row, y| {
        const mosaic_y: i32 = @intCast(y - y % options.mosaic_height);
        const start_x = options.origin_x + @as(i32, options.dmx) * mosaic_y;
        const start_y = options.origin_y + @as(i32, options.dmy) * mosaic_y;
        for (row, 0..) |*pixel, x| {
            const mosaic_x: i32 = @intCast(x - x % options.mosaic_width);
            const source_x = (start_x + @as(i32, options.dx) * mosaic_x) >> 8;
            const source_y = (start_y + @as(i32, options.dy) * mosaic_x) >> 8;

            // A transparent index or an out-of-bounds coordinate shows the backdrop.
            var index: u8 = 0;
            if (source_x >= 0 and source_x < width and source_y >= 0 and source_y < height) {
                const offset = @as(usize, @intCast(source_y)) * width +
                    @as(usize, @intCast(source_x));
                index = bitmap[offset];
            }
            pixel.* = colors[index];
        }
        if (options.green_swap) swapGreen(row);
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
