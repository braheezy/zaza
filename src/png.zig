//! Encode the native GBA framebuffer as an 8-bit RGB PNG.
const std = @import("std");
const video = @import("libzaza").video;
const flate = std.compress.flate;
const Writer = std.Io.Writer;

pub fn write(writer: *Writer, allocator: std.mem.Allocator, frame: *const video.Frame) !void {
    var compressed = try Writer.Allocating.initCapacity(allocator, 4096);
    defer compressed.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&compressed.writer, &window, .zlib, .fastest);
    var row: [1 + video.width * 3]u8 = undefined;
    row[0] = 0; // Each scanline uses PNG's None filter.
    for (frame) |*pixels| {
        for (pixels, 0..) |pixel, x| {
            row[1 + x * 3 ..][0..3].* = .{ pixel.red, pixel.green, pixel.blue };
        }
        try compressor.writer.writeAll(&row);
    }
    try compressor.finish();

    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], video.width, .big);
    std.mem.writeInt(u32, header[4..8], video.height, .big);
    header[8] = 8; // Bits per channel.
    header[9] = 2; // RGB without alpha.
    try writer.writeAll("\x89PNG\r\n\x1a\n");
    try writeChunk(writer, "IHDR", &header);
    try writeChunk(writer, "IDAT", compressed.written());
    try writeChunk(writer, "IEND", &.{});
}

fn writeChunk(writer: *Writer, tag: *const [4]u8, data: []const u8) Writer.Error!void {
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(tag);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc.final(), .big);
}
