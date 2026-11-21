const std = @import("std");
const video = @import("video.zig");

const header_size = 54;
const row_size = video.width * 3;
const pixel_bytes = row_size * video.height;

pub fn write(writer: *std.Io.Writer, frame: *const video.Frame) std.Io.Writer.Error!void {
    // BMP rows are padded to four bytes; the fixed GBA width needs no padding.
    comptime std.debug.assert(row_size % 4 == 0);
    var header: [header_size]u8 = @splat(0);
    header[0..2].* = "BM".*;
    std.mem.writeInt(u32, header[2..6], header_size + pixel_bytes, .little);
    std.mem.writeInt(u32, header[10..14], header_size, .little);
    std.mem.writeInt(u32, header[14..18], 40, .little); // BITMAPINFOHEADER size.
    std.mem.writeInt(i32, header[18..22], video.width, .little);
    std.mem.writeInt(i32, header[22..26], video.height, .little);
    std.mem.writeInt(u16, header[26..28], 1, .little); // Color planes.
    std.mem.writeInt(u16, header[28..30], 24, .little);
    std.mem.writeInt(u32, header[34..38], pixel_bytes, .little);
    try writer.writeAll(&header);

    // A positive BMP height stores the bottom row first, in blue-green-red order.
    var row: [row_size]u8 = undefined;
    for (0..video.height) |row_index| {
        for (&frame[video.height - 1 - row_index], 0..) |pixel, x| {
            row[x * 3 ..][0..3].* = .{ pixel.blue, pixel.green, pixel.red };
        }
        try writer.writeAll(&row);
    }
}

test "BMP writes its header and bottom-up BGR pixels" {
    const black: video.Rgb = .{ .red = 0, .green = 0, .blue = 0 };
    var frame: video.Frame = @splat(@splat(black));
    frame[0][0].red = 255;
    frame[video.height - 1][0].blue = 255;
    var bytes: [header_size + pixel_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try write(&writer, &frame);
    try std.testing.expectEqual(bytes.len, writer.buffered().len);
    try std.testing.expectEqualStrings("BM", bytes[0..2]);
    try std.testing.expectEqual(@as(u32, bytes.len), std.mem.readInt(u32, bytes[2..6], .little));
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, bytes[header_size..][0..3]);
    const top_row = header_size + pixel_bytes - row_size;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, bytes[top_row..][0..3]);
}
