const std = @import("std");
const Psg = @This();

regs: [17]u16 = @splat(0),
active: u4 = 0,
length: [4]u16 = @splat(0),
remaining: [4]u32 = @splat(0),
square_phase: [2]u3 = @splat(0),
wave_phase: u5 = 0,
lfsr: u15 = 0x7FFF,
volume: [4]u4 = @splat(0),
envelope_ticks: [4]u8 = @splat(0),
sweep_shadow: u16 = 0,
sweep_ticks: u8 = 0,
sweep_enabled: bool = false,
sweep_subtracted: bool = false,
sequencer_cycles: u16 = 0,
next_step: u3 = 0,

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

const frame_period = (1 << 24) / 512;
const frequency_regs = [4]usize{ 2, 6, 10, 14 };
const level_regs = [4]usize{ 1, 4, 9, 12 };

pub fn read(self: *const Psg, offset: u32) u16 {
    return self.regs[offset / 2] & psg_registers[offset / 2].readable;
}

fn bit(ch: usize) u4 {
    return @as(u4, 1) << @intCast(ch);
}

fn dacEnabled(self: *const Psg, ch: usize) bool {
    return if (ch == 2) self.regs[8] & 0x80 != 0 else self.regs[level_regs[ch]] & 0xF800 != 0;
}

pub fn write(self: *Psg, offset: u32, byte: u8) void {
    const reg = offset / 2;
    const old = self.regs[reg];
    const shift: u4 = @intCast((offset & 1) * 8);
    self.regs[reg] = ((old & ~(@as(u16, 255) << shift)) | (@as(u16, byte) << shift)) & psg_registers[reg].writable;
    if (offset == 0 and self.sweep_subtracted and old & 8 != 0 and byte & 8 == 0) self.active &= ~bit(0);

    const ch: usize = switch (offset) {
        2...5 => 0,
        8...9, 12...13 => 1,
        16...21 => 2,
        24...25, 28...29 => 3,
        else => return,
    };
    if (reg == level_regs[ch] and offset & 1 == 0) {
        self.length[ch] = if (ch == 2) 256 - @as(u16, byte) else 64 - @as(u16, byte & 63);
    }
    if (!self.dacEnabled(ch)) self.active &= ~bit(ch);
    if (reg != frequency_regs[ch] or offset & 1 == 0) return;

    // Enabling length between length clocks can consume the first tick immediately.
    const extra_length = byte & 0x40 != 0 and self.next_step & 1 != 0;
    if (extra_length and old & 0x4000 == 0) self.clockLength(ch);
    if (byte & 0x80 == 0) return;
    if (self.length[ch] == 0) {
        self.length[ch] = if (ch == 2) 256 else 64;
        self.length[ch] -= @intFromBool(extra_length);
    }
    if (self.dacEnabled(ch)) self.active |= bit(ch);
    self.remaining[ch] = self.period(ch);
    if (ch == 2) {
        self.wave_phase = 0;
    } else {
        const env = self.regs[level_regs[ch]] >> 8;
        self.volume[ch] = @truncate(env >> 4);
        self.envelope_ticks[ch] = pace(env & 7);
    }
    if (ch == 3) self.lfsr = 0x7FFF;
    if (ch == 0) {
        self.sweep_shadow = self.regs[2] & 2047;
        self.sweep_ticks = pace((self.regs[0] >> 4) & 7);
        self.sweep_enabled = self.regs[0] & 0x77 != 0;
        self.sweep_subtracted = false;
        if (self.regs[0] & 7 != 0) _ = self.sweepFrequency();
    }
}

fn pace(value: u16) u8 {
    return if (value == 0) 8 else @intCast(value);
}

fn period(self: *const Psg, ch: usize) u32 {
    const control = self.regs[frequency_regs[ch]];
    if (ch == 3) {
        const divisor: u32 = control & 7;
        const clocks = if (divisor == 0) 32 else 64 * divisor;
        return clocks << @intCast((control >> 4) & 15);
    }
    return (2048 - @as(u32, control & 2047)) * @as(u32, if (ch == 2) 8 else 16);
}

pub fn advance(self: *Psg, cycles: u64) void {
    var left = cycles;
    while (left != 0) {
        const batch: u32 = @intCast(@min(left, frame_period - self.sequencer_cycles));
        for (0..4) |ch| {
            if (self.active & bit(ch) == 0) continue;
            if (batch < self.remaining[ch]) {
                self.remaining[ch] -= batch;
                continue;
            }
            const elapsed = batch - self.remaining[ch];
            const reload = self.period(ch);
            const steps = 1 + elapsed / reload;
            self.remaining[ch] = reload - elapsed % reload;
            switch (ch) {
                0, 1 => self.square_phase[ch] +%= @truncate(steps),
                2 => {
                    const position = self.wave_phase + @as(u32, steps);
                    if (self.regs[8] & 0x20 != 0 and position & 32 != 0) self.regs[8] ^= 0x40;
                    self.wave_phase = @truncate(position);
                },
                3 => {
                    if ((self.regs[14] & 0xF0) >= 0xE0) continue;
                    for (0..steps) |_| {
                        const feedback = (self.lfsr ^ (self.lfsr >> 1)) & 1;
                        self.lfsr = (self.lfsr >> 1) | (feedback << 14);
                        if (self.regs[14] & 8 != 0) self.lfsr = (self.lfsr & ~@as(u15, 64)) | (feedback << 6);
                    }
                },
                else => unreachable,
            }
        }
        self.sequencer_cycles += @intCast(batch);
        if (self.sequencer_cycles == frame_period) {
            self.sequencer_cycles = 0;
            self.clockSequencer();
        }
        left -= batch;
    }
}

fn clockLength(self: *Psg, ch: usize) void {
    if (self.length[ch] == 0) return;
    self.length[ch] -= 1;
    if (self.length[ch] == 0) self.active &= ~bit(ch);
}

fn clockSequencer(self: *Psg) void {
    const step = self.next_step;
    self.next_step +%= 1;
    if (step & 1 == 0) {
        for (0..4) |ch| if (self.regs[frequency_regs[ch]] & 0x4000 != 0) self.clockLength(ch);
    }
    if ((step == 2 or step == 6) and self.active & 1 != 0 and self.sweep_enabled) self.clockSweep();
    if (step == 7) {
        for ([_]usize{ 0, 1, 3 }) |ch| {
            const env = self.regs[level_regs[ch]] >> 8;
            if (self.active & bit(ch) == 0 or env & 7 == 0) continue;
            self.envelope_ticks[ch] -= 1;
            if (self.envelope_ticks[ch] == 0) {
                self.envelope_ticks[ch] = pace(env & 7);
                if (env & 8 != 0) self.volume[ch] +|= 1 else self.volume[ch] -|= 1;
            }
        }
    }
}

fn sweepFrequency(self: *Psg) u16 {
    const sweep = self.regs[0];
    const delta = self.sweep_shadow >> @intCast(sweep & 7);
    if (sweep & 8 != 0) {
        self.sweep_subtracted = true;
        return self.sweep_shadow - delta;
    }
    const next = self.sweep_shadow + delta;
    if (next > 2047) self.active &= ~bit(0);
    return next;
}

fn clockSweep(self: *Psg) void {
    self.sweep_ticks -= 1;
    if (self.sweep_ticks != 0) return;
    const time = (self.regs[0] >> 4) & 7;
    self.sweep_ticks = pace(time);
    if (time == 0) return;
    const next = self.sweepFrequency();
    if (next > 2047 or self.regs[0] & 7 == 0) return;
    self.sweep_shadow = next;
    self.regs[2] = (self.regs[2] & ~@as(u16, 2047)) | next;
    _ = self.sweepFrequency(); // Hardware also checks the following addition for overflow.
}

fn output(self: *const Psg, ch: usize, ram: *const [2][16]u8) u8 {
    if (ch < 2) {
        const duties = [4]u8{ 0x80, 0x81, 0xE1, 0x7E };
        const duty = duties[(self.regs[level_regs[ch]] >> 6) & 3];
        return if ((duty >> self.square_phase[ch]) & 1 != 0) self.volume[ch] else 0;
    }
    if (ch == 3) return if (self.lfsr & 1 == 0) self.volume[3] else 0;
    const packed_pair = ram[self.waveBank()][self.wave_phase / 2];
    const sample = if (self.wave_phase & 1 == 0) packed_pair >> 4 else packed_pair & 15;
    const level = self.regs[9] >> 13;
    if (level & 4 != 0) return sample * 3 / 4;
    return switch (level) {
        1 => sample,
        2 => sample >> 1,
        3 => sample >> 2,
        else => 0,
    };
}

pub fn waveBank(self: *const Psg) u1 {
    return @truncate(self.regs[8] >> 6);
}

pub fn mix(self: *const Psg, left: bool, ratio: u2, ram: *const [2][16]u8) i16 {
    const control = self.regs[16];
    const routes: u4 = @truncate(control >> @as(u4, if (left) 12 else 8));
    var sum: i16 = 0;
    for (0..4) |ch| {
        if (routes & self.active & bit(ch) != 0) sum += self.output(ch, ram);
    }
    const gain: i16 = @intCast(1 + ((control >> @as(u4, if (left) 4 else 0)) & 7));
    return switch (ratio) {
        0 => (sum * gain) >> 2,
        1 => (sum * gain) >> 1,
        2 => sum * gain,
        3 => 0,
    };
}
