const std = @import("std");
const Timers = @This();

pub const base: u32 = 0x0400_0100;
const no_deadline = std.math.maxInt(u64);
const prescalers = [_]u16{ 1, 64, 256, 1024 };
// All channels sample the same free-running ten-bit divider.
divider: u10 = 0,
// Counter values lag by pending_cycles; the deadline is relative to the current cycle.
pending_cycles: u64 = 0,
until_overflow: u64 = no_deadline,
overflowed: u4 = 0,
channels: [4]Timer = @splat(.{}),

pub const Timer = struct {
    reload: u16 = 0,
    counter: u16 = 0,
    control: u8 = 0,
    startup: u1 = 0,
};

pub fn contains(address: u32) bool {
    return address >= base and address < base + 16;
}

pub fn read(self: *Timers, comptime T: type, address: u32) T {
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= base + 16);
    self.syncCounters();
    var result: T = 0;
    for (0..@sizeOf(T)) |index| {
        const offset = address - base + @as(u32, @intCast(index));
        const timer = self.channels[offset / 4];
        const byte: u8 = switch (offset % 4) {
            0 => @truncate(timer.counter),
            1 => @truncate(timer.counter >> 8),
            2 => timer.control,
            3 => 0,
            else => unreachable,
        };
        result |= @as(T, byte) << @intCast(index * 8);
    }
    return result;
}

pub fn write(self: *Timers, comptime T: type, address: u32, value: T) void {
    std.debug.assert(contains(address));
    std.debug.assert(address + @sizeOf(T) <= base + 16);
    self.syncCounters();
    for (0..@sizeOf(T)) |index| {
        const offset = address - base + @as(u32, @intCast(index));
        const timer = &self.channels[offset / 4];
        const byte: u8 = @truncate(value >> @intCast(index * 8));
        switch (offset % 4) {
            0 => timer.reload = (timer.reload & 0xFF00) | byte,
            1 => timer.reload = (timer.reload & 0x00FF) | (@as(u16, byte) << 8),
            2 => {
                const was_enabled = timer.control & 0x80 != 0;
                timer.control = byte & @as(u8, if (offset / 4 == 0) 0xC3 else 0xC7);
                if (!was_enabled and timer.control & 0x80 != 0) {
                    timer.counter = timer.reload;
                    timer.startup = 1;
                }
            },
            3 => {},
            else => unreachable,
        }
    }
    self.until_overflow = self.nextOverflow();
}

pub fn cyclesUntilOverflow(self: *const Timers) u64 {
    return self.until_overflow;
}

// Cascade timers only tick when a clock-driven timer overflows.
fn nextOverflow(self: *const Timers) u64 {
    var earliest: u64 = std.math.maxInt(u64);
    for (self.channels) |timer| {
        if (timer.control & 0x80 == 0 or timer.control & 4 != 0) continue;
        const ticks = @as(u64, 0x10000) - timer.counter;
        const period = prescalers[timer.control & 3];
        const phase = (@as(u16, self.divider) + timer.startup) % period;
        earliest = @min(earliest, timer.startup + ticks * period - phase);
    }
    return earliest;
}

// Before an overflow only the divider or the amount of deferred work changes.
pub fn advanceBeforeOverflow(self: *Timers, cycles: u64) void {
    std.debug.assert(cycles < self.until_overflow);
    self.overflowed = 0;
    if (self.until_overflow == no_deadline) {
        self.divider +%= @truncate(cycles);
    } else {
        self.pending_cycles += cycles;
        self.until_overflow -= cycles;
    }
}

pub fn advance(self: *Timers, cycles: u64) u14 {
    if (cycles < self.until_overflow) {
        self.advanceBeforeOverflow(cycles);
        return 0;
    }
    self.overflowed = 0;
    if (self.until_overflow == no_deadline) {
        self.divider +%= @truncate(cycles);
        return 0;
    }
    self.syncCounters();
    const interrupts = self.advanceCounters(cycles);
    self.until_overflow = self.nextOverflow();
    return interrupts;
}

fn syncCounters(self: *Timers) void {
    if (self.pending_cycles == 0) return;
    const interrupts = self.advanceCounters(self.pending_cycles);
    std.debug.assert(interrupts == 0);
    self.pending_cycles = 0;
}

fn advanceCounters(self: *Timers, cycles: u64) u14 {
    const start = self.divider;
    self.divider +%= @truncate(cycles);
    var previous_overflows: u64 = 0;
    var interrupts: u14 = 0;
    for (&self.channels, 0..) |*timer, index| {
        if (timer.control & 0x80 == 0) {
            previous_overflows = 0;
            continue;
        }
        var ticks = previous_overflows;
        if (timer.control & 4 == 0) {
            const period = prescalers[timer.control & 3];
            const phase = (@as(u16, start) + timer.startup) % period;
            const counting = cycles -| timer.startup;
            if (cycles != 0) timer.startup = 0;
            ticks = counting / period;
            const remainder = counting % period + phase;
            ticks += remainder / period;
        }
        const until_overflow = @as(u64, 0x10000) - timer.counter;
        previous_overflows = 0;
        if (ticks < until_overflow) {
            timer.counter += @intCast(ticks);
        } else {
            const period = @as(u64, 0x10000) - timer.reload;
            const remaining = ticks - until_overflow;
            self.overflowed |= @as(u4, 1) << @intCast(index);
            previous_overflows = 1 + remaining / period;
            timer.counter = timer.reload + @as(u16, @intCast(remaining % period));
            if (timer.control & 0x40 != 0) interrupts |= @as(u14, 1) << @intCast(3 + index);
        }
    }
    return interrupts;
}

test "timer reload writes do not replace a running counter and overflow cascades" {
    var timers: Timers = .{};
    timers.write(u32, base, 0x00C0_FFFE);
    timers.write(u32, base + 4, 0x00C4_FFFF);
    try std.testing.expectEqual(@as(u14, 0), timers.advance(2));
    timers.write(u16, base, 0xFFFD);
    try std.testing.expectEqual(@as(u16, 0xFFFF), timers.read(u16, base));
    try std.testing.expectEqual(@as(u14, 0x18), timers.advance(1));
    try std.testing.expectEqual(@as(u16, 0xFFFD), timers.read(u16, base));
    try std.testing.expectEqual(@as(u14, 0x18), timers.advance(6));
}

test "all timer prescalers retain fractional cycles and disabled timers stop" {
    for ([_]u16{ 1, 64, 256, 1024 }, 0..) |period, select| {
        var timers: Timers = .{};
        timers.write(u8, base + 2, 0x80 | @as(u8, @intCast(select)));
        _ = timers.advance(if (period == 1) 1 else period - 1);
        try std.testing.expectEqual(@as(u16, 0), timers.read(u16, base));
        _ = timers.advance(1);
        try std.testing.expectEqual(@as(u16, 1), timers.read(u16, base));
        timers.write(u8, base + 2, 0);
        _ = timers.advance(1024);
        try std.testing.expectEqual(@as(u16, 1), timers.read(u16, base));
    }
}

test "staggered timer enables share a divider edge across wraparound" {
    var timers: Timers = .{};
    _ = timers.advance(1000);
    timers.write(u32, base, 0x00C1_FFFF); // Divide by 64.
    _ = timers.advance(20);
    timers.write(u32, base + 4, 0x00C3_FFFF); // Divide by 1024.
    try std.testing.expectEqual(@as(u64, 4), timers.cyclesUntilOverflow());
    try std.testing.expectEqual(@as(u14, 0), timers.advance(3));
    try std.testing.expectEqual(@as(u14, 0x18), timers.advance(1));

    // Changing the rate of a running timer also selects an existing divider tap.
    timers.write(u8, base + 2, 0);
    _ = timers.advance(200);
    timers.write(u8, base + 6, 0xC2);
    try std.testing.expectEqual(@as(u64, 56), timers.cyclesUntilOverflow());
    try std.testing.expectEqual(@as(u14, 0x10), timers.advance(56));
}

test "timer control byte masks and restart load the latest reload value" {
    // Timer zero has no cascade input; high control bytes are unused.
    var timers: Timers = .{};
    timers.write(u16, base, 0x1234);
    timers.write(u16, base + 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x00C3_1234), timers.read(u32, base));
    timers.write(u16, base, 0x5678);
    timers.write(u8, base + 2, 0);
    timers.write(u8, base + 2, 0x80);
    try std.testing.expectEqual(@as(u16, 0x5678), timers.read(u16, base));
}
