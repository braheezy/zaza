const std = @import("std");
const Audio = @This();

pub const base: u32 = 0x0400_0060;
const end: u32 = 0x0400_00B0;
const wave_start = 0x30;
const fifo_start = 0x40;
const fifo_end = 0x48;
const master_enable = 0x80;

// The PSG registers include write-only frequency and length fields.
psg: [0x22 / 2]u16 = @splat(0),
master_enabled: bool = false,
active_channels: u4 = 0,
direct_control: u16 = 0,
bias: u16 = 0x0200,
wave_ram: [2][16]u8 = @splat(@splat(0)),
fifos: [2]Fifo = @splat(.{}),

const Fifo = struct {
    words: [8]u32 = @splat(0),
    count: u8 = 0,

    fn push(self: *Fifo, word: u32) void {
        // Playback and the hardware's full-FIFO behavior need a clocked consumer.
        if (self.count == self.words.len) return;
        self.words[self.count] = word;
        self.count += 1;
    }
};

const Register = struct { writable: u16, readable: u16 };

// Trigger bits are commands and are handled separately from stored configuration.
const psg_registers = [_]Register{
    .{ .writable = 0x007F, .readable = 0x007F }, // SOUND1CNT_L
    .{ .writable = 0xFFFF, .readable = 0xFFC0 }, // SOUND1CNT_H
    .{ .writable = 0x47FF, .readable = 0x4000 }, // SOUND1CNT_X
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0xFFFF, .readable = 0xFFC0 }, // SOUND2CNT_L
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0x47FF, .readable = 0x4000 }, // SOUND2CNT_H
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0x00E0, .readable = 0x00E0 }, // SOUND3CNT_L
    .{ .writable = 0xE0FF, .readable = 0xE000 }, // SOUND3CNT_H
    .{ .writable = 0x47FF, .readable = 0x4000 }, // SOUND3CNT_X
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0xFF3F, .readable = 0xFF00 }, // SOUND4CNT_L
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0x40FF, .readable = 0x40FF }, // SOUND4CNT_H
    .{ .writable = 0, .readable = 0 }, // unused
    .{ .writable = 0xFF77, .readable = 0xFF77 }, // SOUNDCNT_L
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
        0...0x21 => self.psg[offset / 2] & psg_registers[offset / 2].readable,
        0x22...0x23 => self.direct_control,
        0x24...0x25 => if (self.master_enabled) master_enable | @as(u16, self.active_channels) else 0,
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
        if (T != u32) @panic("narrow sound FIFO writes are not modeled");
        self.fifos[(start - fifo_start) / 4].push(value);
        return;
    }
    for (0..@sizeOf(T)) |index| {
        const offset = start + @as(u32, @intCast(index));
        self.writeByte(offset, @truncate(value >> @intCast(index * 8)));
    }
}

fn writeByte(self: *Audio, offset: u32, byte: u8) void {
    switch (offset) {
        0...0x21 => self.writePsg(offset, byte),
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
                self.psg = @splat(0);
                self.active_channels = 0;
            }
        },
        0x28...0x29 => self.bias = mergeByte(self.bias, offset, byte) & 0xC3FE,
        wave_start...fifo_start - 1 => self.wave_ram[self.cpuWaveBank()][offset - wave_start] = byte,
        else => {}, // The BIOS clears unused lanes with word stores.
    }
}

fn writePsg(self: *Audio, offset: u32, byte: u8) void {
    if (!self.master_enabled) return;
    const index = offset / 2;
    self.psg[index] = mergeByte(self.psg[index], offset, byte) & psg_registers[index].writable;

    // Status tracks triggers and DAC shutdown. Natural expiry needs the PSG clock.
    const channel: u2 = switch (offset) {
        0x03, 0x05 => 0,
        0x09, 0x0D => 1,
        0x10, 0x15 => 2,
        0x19, 0x1D => 3,
        else => return,
    };
    const dac_enabled = switch (channel) {
        0 => self.psg[1] & 0xF800 != 0,
        1 => self.psg[4] & 0xF800 != 0,
        2 => self.psg[8] & 0x0080 != 0,
        3 => self.psg[12] & 0xF800 != 0,
    };
    const flag = @as(u4, 1) << channel;
    if (!dac_enabled) {
        self.active_channels &= ~flag;
    } else {
        switch (offset) {
            0x05, 0x0D, 0x15, 0x1D => if (byte & 0x80 != 0) {
                self.active_channels |= flag;
            },
            else => {},
        }
    }
}

fn cpuWaveBank(self: *const Audio) usize {
    // The CPU accesses the bank opposite the one selected for playback.
    return @intFromBool(self.psg[8] & 0x0040 == 0);
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
    try std.testing.expectEqual(@as(u8, 1), audio.fifos[1].count);
    try std.testing.expectEqual(@as(u32, 0x89AB_CDEF), audio.fifos[1].words[0]);
    try std.testing.expectEqual(@as(u8, 0), audio.read(u8, base + 0x23));
}
