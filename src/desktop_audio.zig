// Single producer (emulation thread), single consumer (Mach audio callback).
const std = @import("std");
const zaza = @import("libzaza");
const sysaudio = @import("mach").sysaudio;
const Playback = @This();

const capacity = 4096;
const Stereo = [2]i16;
const Cursor = std.atomic.Value(u32);

context: sysaudio.Context,
player: sysaudio.Player,
pcm: std.Io.Writer.Allocating,
capture: zaza.AudioCapture,
frames: [capacity]Stereo = undefined,
published: Cursor = Cursor.init(0),
consumed: Cursor = Cursor.init(0),
fraction: u32 = 0,
primed: bool = false,
rate: u32,
channels: usize,
volume: u8,

// The callback retains this address until player.deinit stops the stream.
pub fn init(self: *Playback, allocator: std.mem.Allocator, volume: u8) !void {
    var context = try sysaudio.Context.init(null, allocator, .{ .app_name = "Zaza" });
    errdefer context.deinit();
    try context.refresh();
    const device = context.defaultDevice(.playback) orelse return error.NoPlaybackDevice;
    if (device.channels.len == 0 or device.sample_rate.max < 8000) return error.InvalidPlaybackDevice;
    var player = try context.createPlayer(device, render, .{
        .format = .i16,
        .sample_rate = device.sample_rate.max,
        .user_data = self,
    });
    errdefer player.deinit();
    self.* = .{
        .context = context,
        .player = player,
        .pcm = .init(allocator),
        .capture = .{ .writer = &self.pcm.writer },
        .rate = player.sampleRate(),
        .channels = player.channels().len,
        .volume = volume,
    };
    try self.player.start();
}

pub fn deinit(self: *Playback) void {
    self.player.deinit();
    self.context.deinit();
    self.pcm.deinit();
}

pub fn publish(self: *Playback) void {
    const bytes = self.pcm.written();
    const head = self.published.load(.monotonic);
    const tail = self.consumed.load(.acquire);
    const count = @min(bytes.len / 4, capacity - (head -% tail));
    for (0..count) |i| {
        self.frames[(head +% @as(u32, @intCast(i))) % capacity] = .{
            std.mem.readInt(i16, bytes[i * 4 ..][0..2], .little),
            std.mem.readInt(i16, bytes[i * 4 + 2 ..][0..2], .little),
        };
    }
    self.published.store(head +% @as(u32, @intCast(count)), .release);
    self.pcm.clearRetainingCapacity();
    self.capture.bytes = 0;
}

fn render(user_data: ?*anyopaque, output: []u8) void {
    const self: *Playback = @ptrCast(@alignCast(user_data.?));
    @memset(output, 0);
    const head = self.published.load(.acquire);
    var tail = self.consumed.load(.monotonic);
    // Accumulate two video frames of source audio after startup or an underrun.
    if (!self.primed and head -% tail < 1100) return;
    self.primed = true;
    const frame_size = self.channels * 2;
    for (0..output.len / frame_size) |i| {
        const advance = (self.fraction + zaza.sample_rate) / self.rate;
        if (head -% tail < @max(2, advance)) {
            self.primed = false;
            break;
        }
        const a = self.frames[tail % capacity];
        const b = self.frames[(tail +% 1) % capacity];
        var pair: Stereo = undefined;
        for (&pair, a, b) |*out, first, second| {
            const delta = @as(i64, second) - first;
            const sample = first + @divTrunc(delta * self.fraction, self.rate);
            out.* = @intCast(@divTrunc(sample * self.volume, 100));
        }
        const offset = i * frame_size;
        if (self.channels == 1) {
            const mono: i16 = @intCast(@divTrunc(@as(i32, pair[0]) + pair[1], 2));
            std.mem.writeInt(i16, output[offset..][0..2], mono, .little);
        } else {
            std.mem.writeInt(i16, output[offset..][0..2], pair[0], .little);
            std.mem.writeInt(i16, output[offset + 2 ..][0..2], pair[1], .little);
        }
        tail +%= advance;
        self.fraction = (self.fraction + zaza.sample_rate) % self.rate;
    }
    self.consumed.store(tail, .release);
}
