const std = @import("std");
const Audio = @This();

pub const base: u32 = 0x0400_0060;
const end: u32 = 0x0400_00B0;
const wave_start = 0x30;
const fifo_start = 0x40;
const fifo_end = 0x48;
const master_enable = 0x80;

psg: @import("psg.zig") = .{},
master_enabled: bool = false,
direct_control: u16 = 0,
bias: u16 = 0x0200,
wave_ram: [2][16]u8 = @splat(@splat(0)),
fifos: [2]Fifo = @splat(.{}),

// Tracks the sample clock even when no host is collecting PCM.
sample_phase: u9 = 0,
capture: ?*Capture = null,
pub const sample_period = 512;
pub const sample_rate = (1 << 24) / sample_period;

pub const Capture = struct {
    writer: *std.Io.Writer,
    bytes: u32 = 0,
    failure: ?error{ WriteFailed, WavTooLarge } = null,

    pub fn sample(self: *Capture, audio: *const Audio) void {
        if (self.failure != null) return;
        if (self.bytes > std.math.maxInt(u32) - 40) {
            self.failure = error.WavTooLarge;
            return;
        }
        var pcm: [4]u8 = undefined;
        std.mem.writeInt(i16, pcm[0..2], audio.mix(true), .little);
        std.mem.writeInt(i16, pcm[2..4], audio.mix(false), .little);
        self.writer.writeAll(&pcm) catch {
            self.failure = error.WriteFailed;
            return;
        };
        self.bytes += 4;
    }
};

fn mix(self: *const Audio, left: bool) i16 {
    if (!self.master_enabled) return 0;
    var level: i16 = @intCast(self.bias & 0x3FF);
    level += self.psg.mix(left, @truncate(self.direct_control), &self.wave_ram);
    for (self.fifos, 0..) |fifo, i| {
        const route: u16 = if (left) 0x0200 else 0x0100;
        if (self.direct_control & (route << @intCast(4 * i)) == 0) continue;
        const full = self.direct_control & (@as(u16, 4) << @intCast(i)) != 0;
        level += @as(i16, fifo.sample) * @as(i16, if (full) 2 else 1);
    }
    return (std.math.clamp(level, 0, 1023) - 512) * 64;
}

// Each selected timer clocks one signed PCM byte, independently of its IRQ enable.
pub fn clockFifos(self: *Audio, overflowed: u4) u2 {
    if (!self.master_enabled) return 0;
    var requests: u2 = 0;
    for (&self.fifos, 0..) |*fifo, i| {
        const control = self.direct_control >> @intCast(8 + i * 4);
        if (control & 3 == 0) continue;
        const timer: u1 = @truncate(control >> 2);
        if (overflowed & (@as(u4, 1) << timer) == 0) continue;
        // The refill decision sees queued words before the output stage takes one.
        if (fifo.count <= 3 * @sizeOf(u32)) requests |= @as(u2, 1) << @intCast(i);
        fifo.clock();
    }
    return requests;
}

const Fifo = struct {
    head: u5 = 0,
    sample: i8 = 0,
    bytes: [32]u8 = @splat(0),
    count: u8 = 0,

    output_word: u32 = 0,
    output_bytes: u3 = 0,

    fn clock(self: *Fifo) void {
        if (self.output_bytes == 0) {
            self.output_bytes = @intCast(@min(self.count, @sizeOf(u32)));
            for (0..self.output_bytes) |i| {
                self.output_word |= @as(u32, self.bytes[self.head]) << @intCast(i * 8);
                self.head +%= 1;
            }
            self.count -= self.output_bytes;
        }
        if (self.output_bytes != 0) {
            self.sample = @bitCast(@as(u8, @truncate(self.output_word)));
            self.output_word >>= 8;
            self.output_bytes -= 1;
        }
    }

    fn push(self: *Fifo, comptime T: type, value: T) void {
        for (0..@sizeOf(T)) |lane| {
            if (self.count == self.bytes.len) return;
            self.bytes[self.head +% @as(u5, @truncate(self.count))] = @truncate(value >> @intCast(lane * 8));
            self.count += 1;
        }
    }
};

pub fn contains(address: u32) bool {
    return address >= base and address < end;
}

pub fn read(self: *const Audio, comptime T: type, address: u32) T {
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= end);
    var result: T = 0;
    for (0..@sizeOf(T)) |index| {
        const offset = address - base + @as(u32, @intCast(index));
        const byte = self.readByte(offset);
        result |= @as(T, byte) << @intCast(index * 8);
    }
    return result;
}

fn readByte(self: *const Audio, offset: u32) u8 {
    const halfword: u16 = switch (offset) {
        0...0x21 => self.psg.read(offset),
        0x22...0x23 => self.direct_control,
        0x24...0x25 => if (self.master_enabled) master_enable | @as(u16, self.psg.active) else 0,
        0x28...0x29 => self.bias,
        wave_start...fifo_start - 1 => return self.wave_ram[self.cpuWaveBank()][offset - wave_start],
        fifo_start...fifo_end - 1 => @panic("sound FIFO read needs open bus"),
        else => 0, // Open-bus behavior for unused I/O is not modeled.
    };
    return @truncate(halfword >> @intCast((offset & 1) * 8));
}

pub fn write(self: *Audio, comptime T: type, address: u32, value: T) void {
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= end);
    const start = address - base;
    if (start >= fifo_start and start < fifo_end) {
        self.fifos[(start - fifo_start) / 4].push(T, value);
        return;
    }
    for (0..@sizeOf(T)) |index| {
        const offset = start + @as(u32, @intCast(index));
        self.writeByte(offset, @truncate(value >> @intCast(index * 8)));
    }
}

fn writeByte(self: *Audio, offset: u32, byte: u8) void {
    switch (offset) {
        0...0x21 => if (self.master_enabled) self.psg.write(offset, byte),
        0x22...0x23 => {
            if (offset == 0x23) {
                if (byte & 0x08 != 0) self.fifos[0] = .{};
                if (byte & 0x80 != 0) self.fifos[1] = .{};
            }
            self.direct_control = mergeByte(self.direct_control, offset, byte) & 0x770F;
        },
        0x24 => {
            self.master_enabled = byte & master_enable != 0;
            if (!self.master_enabled) {
                self.psg = .{};
            }
        },
        0x28...0x29 => self.bias = mergeByte(self.bias, offset, byte) & 0xC3FE,
        wave_start...fifo_start - 1 => self.wave_ram[self.cpuWaveBank()][offset - wave_start] = byte,
        else => {}, // The BIOS clears unused lanes with word stores.
    }
}

fn cpuWaveBank(self: *const Audio) usize {
    // The CPU accesses the bank opposite the one selected for playback.
    return self.psg.waveBank() ^ 1;
}

fn mergeByte(previous: u16, offset: u32, byte: u8) u16 {
    const shift: u4 = @intCast((offset & 1) * 8);
    return (previous & ~(@as(u16, 0xFF) << shift)) | (@as(u16, byte) << shift);
}

test "PSG trigger and master reset respect register read and write masks" {
    var audio: Audio = .{};
    audio.write(u16, base + 2, 0xF0FF);
    audio.write(u8, base + 0x24, 0xFF);
    try std.testing.expectEqual(@as(u16, 0), audio.read(u16, base + 2));
    audio.write(u32, base, 0xF0FF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xF0C0_007F), audio.read(u32, base));
    audio.write(u16, base + 4, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x4000), audio.read(u16, base + 4));
    try std.testing.expectEqual(@as(u8, 0x81), audio.read(u8, base + 0x24));
    audio.write(u8, base + 3, 0);
    try std.testing.expectEqual(@as(u8, 0x80), audio.read(u8, base + 0x24));

    audio.write(u32, base + 0x20, 0x770F_FFFF);
    audio.write(u16, base + 0x28, 0xFFFF);
    audio.write(u8, base + 0x24, 0);
    try std.testing.expectEqual(@as(u32, 0x770F_0000), audio.read(u32, base + 0x20));
    try std.testing.expectEqual(@as(u16, 0xC3FE), audio.read(u16, base + 0x28));
}

test "wave bank selection and FIFO reset affect only their own storage" {
    var audio: Audio = .{};
    audio.write(u32, base + wave_start, 0x4433_2211);
    audio.write(u8, base + 0x24, master_enable);
    audio.write(u8, base + 0x10, 0x40);
    audio.write(u16, base + wave_start + 2, 0xAABB);
    try std.testing.expectEqual(@as(u32, 0xAABB_0000), audio.read(u32, base + wave_start));
    audio.write(u8, base + 0x24, 0);
    try std.testing.expectEqual(@as(u32, 0x4433_2211), audio.read(u32, base + wave_start));

    audio.write(u32, base + fifo_start, 0x1234_5678);
    audio.write(u32, base + fifo_start + 4, 0x89AB_CDEF);
    audio.write(u8, base + 0x23, 0x08);
    try std.testing.expectEqual(@as(u8, 0), audio.fifos[0].count);
    try std.testing.expectEqual(@as(u8, 4), audio.fifos[1].count);
    try std.testing.expectEqual(@as(u32, 0x89AB_CDEF), std.mem.readInt(u32, audio.fifos[1].bytes[0..4], .little));
    try std.testing.expectEqual(@as(u8, 0), audio.read(u8, base + 0x23));
}

test "square duty cycles and PSG stereo gains are independent" {
    for ([_]u8{ 1, 2, 4, 6 }, 0..) |high_steps, duty| {
        var audio: Audio = .{};
        audio.write(u8, base + 0x24, 0x80);
        audio.write(u16, base + 0x20, 0x1273); // Square 1 left, square 2 right.
        audio.write(u16, base + 0x22, 2);
        audio.write(u16, base + 2, 0xF000 | @as(u16, @intCast(duty << 6)));
        audio.write(u16, base + 4, 0x87FF);
        audio.write(u16, base + 8, 0x7080);
        audio.write(u16, base + 12, 0x87FF);
        var left_high: u8 = 0;
        var right_high: u8 = 0;
        for (0..8) |_| {
            const left = audio.mix(true);
            const right = audio.mix(false);
            try std.testing.expect(left == 0 or left == 15 * 8 * 64);
            try std.testing.expect(right == 0 or right == 7 * 4 * 64);
            left_high += @intFromBool(left != 0);
            right_high += @intFromBool(right != 0);
            audio.psg.advance(16);
        }
        try std.testing.expectEqual(high_steps, left_high);
        try std.testing.expectEqual(@as(u8, 4), right_high);
    }
}

test "PSG frame sequencer clocks length, sweep overflow and envelopes" {
    var audio: Audio = .{};
    audio.write(u8, base + 0x24, 0x80);
    audio.write(u16, base, 0x11); // Add half the shadow frequency every sweep tick.
    audio.write(u16, base + 2, 0xF080);
    audio.write(u16, base + 4, 0x8400); // 1024 -> 1536 -> next calculation overflows.
    audio.write(u16, base + 8, 0xF13F); // One length tick.
    audio.write(u16, base + 12, 0xC000);
    audio.write(u16, base + 24, 0x2900); // Noise envelope starts at 2 and rises.
    audio.write(u16, base + 28, 0x8000);

    audio.psg.advance(32767);
    try std.testing.expectEqual(@as(u8, 0x8B), audio.read(u8, base + 0x24));
    audio.psg.advance(1);
    try std.testing.expectEqual(@as(u8, 0x89), audio.read(u8, base + 0x24));
    audio.psg.advance(2 * 32768);
    try std.testing.expectEqual(@as(u16, 1536), audio.psg.sweep_shadow);
    try std.testing.expectEqual(@as(u8, 0x88), audio.read(u8, base + 0x24));
    audio.psg.advance(5 * 32768 - 1);
    try std.testing.expectEqual(@as(u4, 2), audio.psg.volume[3]);
    audio.psg.advance(1);
    try std.testing.expectEqual(@as(u4, 3), audio.psg.volume[3]);
}

test "wave RAM plays high nibble first and exchanges CPU and playback banks in 64-sample mode" {
    var audio: Audio = .{};
    audio.write(u8, base + 0x24, 0x80);
    audio.write(u8, base + 0x30, 0x62); // Bank 1
    audio.write(u8, base + 0x10, 0x40);
    audio.write(u8, base + 0x30, 0xC4); // Bank 0
    audio.write(u8, base + 0x10, 0xA0);
    audio.write(u16, base + 0x12, 0x2000);
    audio.write(u16, base + 0x14, 0x87FF);
    audio.write(u16, base + 0x20, 0x4000);
    audio.write(u8, base + 0x22, 2);
    try std.testing.expectEqual(@as(i16, 12 * 64), audio.mix(true));
    audio.psg.advance(8);
    try std.testing.expectEqual(@as(i16, 4 * 64), audio.mix(true));
    audio.psg.advance(31 * 8);
    try std.testing.expectEqual(@as(u8, 0xC4), audio.read(u8, base + 0x30));
    try std.testing.expectEqual(@as(i16, 6 * 64), audio.mix(true));
    audio.write(u8, base + 0x13, 0x80); // Forced 75% volume.
    try std.testing.expectEqual(@as(i16, 4 * 64), audio.mix(true));
    audio.write(u8, base + 0x10, 0);
    try std.testing.expectEqual(@as(i16, 0), audio.mix(true));
}

test "noise feedback repeats at 127 or 32767 clocks and retrigger reseeds it" {
    for ([_]u8{ 0, 8 }, [_]usize{ 32767, 127 }) |width, period| {
        var audio: Audio = .{};
        audio.write(u8, base + 0x24, 0x80);
        audio.write(u16, base + 24, 0xF000);
        audio.write(u16, base + 28, 0x8000 | @as(u16, width));
        const mask: u15 = if (width == 0) 0x7FFF else 0x7F;
        for (1..period) |_| {
            audio.psg.advance(32);
            try std.testing.expect(audio.psg.lfsr & mask != mask);
        }
        audio.psg.advance(32);
        try std.testing.expectEqual(mask, audio.psg.lfsr & mask);
        audio.psg.advance(96);
        audio.write(u8, base + 29, 0x80);
        try std.testing.expectEqual(@as(u15, 0x7FFF), audio.psg.lfsr);
    }
}

test "Direct Sound requests DMA before fetching the next output word" {
    var audio: Audio = .{ .master_enabled = true, .direct_control = 0x0300 };
    const fifo_address = base + fifo_start;
    for (0..35) |tick| {
        const request = audio.clockFifos(1);
        const refill = tick == 0 or tick == 2 or tick == 18 or tick == 34;
        try std.testing.expectEqual(@intFromBool(refill), request);
        if (refill) {
            const start: u8 = switch (tick) {
                0 => 1,
                2 => 17,
                18 => 33,
                34 => 49,
                else => unreachable,
            };
            for (0..16) |offset| audio.write(u8, fifo_address, start + @as(u8, @intCast(offset)));
        }
        try std.testing.expectEqual(@as(i8, @intCast(tick)), audio.fifos[0].sample);
    }
}
