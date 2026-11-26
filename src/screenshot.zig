const std = @import("std");
const video = @import("libzaza").video;
const png = @import("png.zig");
const bmp = @import("bmp.zig");

pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    frame: *const video.Frame,
    mode: enum { exclusive, replace },
) !void {
    var output = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = mode == .replace });
    defer output.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = output.file.writer(io, &buffer);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".png")) {
        try png.write(&writer.interface, allocator, frame);
    } else {
        try bmp.write(&writer.interface, frame);
    }
    try writer.interface.flush();
    switch (mode) {
        .exclusive => try output.link(io),
        .replace => try output.replace(io),
    }
}
