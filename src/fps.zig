const std = @import("std");
const video = @import("video.zig");
const Counter = @This();

start_ns: ?i96 = null,
frames: u32 = 0,
tenths: ?u16 = null,

// Count distinct game frames submitted for display. Repeated host redraws
// still advance the measuring window, so a stalled producer reads zero.
pub fn tick(self: *Counter, now_ns: i96, new_frame: bool) void {
    const start = self.start_ns orelse {
        self.start_ns = now_ns;
        return;
    };
    self.frames += @intFromBool(new_frame);
    const elapsed = now_ns - start;
    if (elapsed < std.time.ns_per_s) return;
    self.tenths = @intCast(@min(9999, @divTrunc(@as(i96, self.frames) * 10 * std.time.ns_per_s + @divTrunc(elapsed, 2), elapsed)));
    self.start_ns = now_ns;
    self.frames = 0;
}

pub fn draw(self: Counter, pixels: *[video.height][video.width][4]u8) void {
    var buf: [16]u8 = undefined;
    const label = if (self.tenths) |n| std.fmt.bufPrint(&buf, "{d}.{d} FPS", .{ n / 10, n % 10 }) catch unreachable else "--.- FPS";
    const left = video.width - 3 - label.len * 4;
    for (pixels[2..9]) |*row| @memset(row[left - 1 .. video.width - 3], .{ 0, 0, 0, 255 });
    for (label, 0..) |c, i| {
        const glyph: u15 = switch (c) {
            '0' => 0b111_101_101_101_111,
            '1' => 0b010_110_010_010_111,
            '2' => 0b111_001_111_100_111,
            '3' => 0b111_001_111_001_111,
            '4' => 0b101_101_111_001_001,
            '5', 'S' => 0b111_100_111_001_111,
            '6' => 0b111_100_111_101_111,
            '7' => 0b111_001_010_010_010,
            '8' => 0b111_101_111_101_111,
            '9' => 0b111_101_111_001_111,
            'F' => 0b111_100_110_100_100,
            'P' => 0b110_101_110_100_100,
            '.' => 0b000_000_000_000_010,
            '-' => 0b000_000_111_000_000,
            else => 0,
        };
        for (0..15) |bit| {
            if (glyph & (@as(u15, 1) << @intCast(14 - bit)) != 0)
                pixels[3 + bit / 3][left + i * 4 + bit % 3] = .{ 255, 255, 255, 255 };
        }
    }
}

test "FPS counts game frames across repeated display refreshes" {
    var counter: Counter = .{};
    for (0..121) |i| counter.tick(@intCast(i * std.time.ns_per_s / 120), i % 2 == 0);
    try std.testing.expectEqual(@as(u16, 600), counter.tenths.?);
    counter.tick(2 * std.time.ns_per_s, false);
    try std.testing.expectEqual(@as(u16, 0), counter.tenths.?);
}

test "overlay draws the label in the top right of the presentation buffer" {
    const color = [4]u8{ 10, 20, 30, 255 };
    var pixels: [video.height][video.width][4]u8 = @splat(@splat(color));
    const counter: Counter = .{ .tenths = 597 };
    counter.draw(&pixels);
    const left = video.width - 3 - "59.7 FPS".len * 4;
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixels[2][left]);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixels[3][left]);
    try std.testing.expectEqual(color, pixels[9][left]);
    try std.testing.expectEqual(color, pixels[2][0]);
}
