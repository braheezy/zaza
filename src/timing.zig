const std = @import("std");

pub const Access = enum { nonsequential, sequential };

pub const cycles_per_line = 1232;
pub const lines_per_frame = 228;
pub const cycles_per_frame = cycles_per_line * lines_per_frame;
pub const bg_enable_latch = 40;
pub const first_pixel_merge = 46;
pub const cycles_per_pixel = 4;
pub const hblank_start = 1006;
pub const vblank_start = cycles_per_line * 160;
pub const vblank_end = cycles_per_line * 227;

pub fn cyclesUntil(phase: u64, edge: u64, period: u64) u64 {
    std.debug.assert(phase < period);
    std.debug.assert(edge < period);
    return if (phase < edge) edge - phase else period - phase + edge;
}

pub fn gamePakAccessCycles(comptime T: type, access: Access, waitcnt: u16, window: u2) u8 {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    std.debug.assert(window < 3);
    const shift: u4 = 2 + @as(u4, window) * 3;
    const first_select: u2 = @truncate(waitcnt >> shift);
    const first_wait = [_]u8{ 4, 3, 2, 8 };
    const slow_seq = [_]u8{ 2, 4, 8 };
    const next_wait: u8 = if (waitcnt & (@as(u16, 4) << shift) != 0) 1 else slow_seq[window];
    // WAITCNT selects wait cycles; each halfword also takes one transfer cycle.
    const first_cycles = 1 + if (access == .nonsequential) first_wait[first_select] else next_wait;
    return first_cycles + if (T == u32) 1 + next_wait else 0;
}

// ROM is immutable, so the FIFO only needs its address and the number of
// sequential bus cycles already spent fetching up to eight halfwords.
pub const CartridgePrefetch = struct {
    next_address: ?u32 = null,
    halfword_cycles: u8 = 0,
    progress: u8 = 0,

    pub fn advance(self: *CartridgePrefetch, cycles: u64) void {
        const capacity = self.halfword_cycles * 8;
        self.progress += @intCast(@min(cycles, capacity - self.progress));
    }

    // A cartridge transfer in its final clock completes before the bus changes owner.
    pub fn stop(self: *CartridgePrefetch) u8 {
        const finishing = self.next_address != null and
            self.progress % self.halfword_cycles == self.halfword_cycles - 1;
        self.* = .{};
        return @intFromBool(finishing);
    }

    pub fn continues(self: *const CartridgePrefetch, address: u32, access: Access) bool {
        return access == .sequential and self.next_address == address and address & 0x1_FFFF != 0;
    }

    pub fn consume(self: *CartridgePrefetch, comptime T: type, address: u32) u8 {
        const needed = self.halfword_cycles * (@sizeOf(T) / 2);
        const cycles = @max(1, needed -| self.progress);
        const buffered = self.progress >= needed;
        self.progress -|= needed;
        if (buffered) self.advance(1);
        self.next_address = address + @sizeOf(T);
        return cycles;
    }

    pub fn fetch(self: *CartridgePrefetch, comptime T: type, address: u32, access: Access, miss_cycles: u8, waitcnt: u16, window: u2) u8 {
        if (self.continues(address, access)) return self.consume(T, address);
        const cycles = miss_cycles + self.stop();
        self.next_address = address + @sizeOf(T);
        self.halfword_cycles = gamePakAccessCycles(u16, .sequential, waitcnt, window);
        return cycles;
    }
};

pub fn ramAccessCycles(comptime T: type, region: u8) u8 {
    // EWRAM uses the default two waits per halfword. 32-bit palette and VRAM
    // accesses likewise use two bus beats, with zero waits absent PPU contention.
    return switch (region) {
        0x02 => if (T == u32) 6 else 3,
        0x05, 0x06 => if (T == u32) 2 else 1,
        else => 1,
    };
}

pub fn saveAccessCycles(waitcnt: u16) u8 {
    const waits = [_]u8{ 4, 3, 2, 8 };
    return 1 + waits[waitcnt & 3];
}

test "Game Pak window 0 charges each halfword of a word access" {
    try std.testing.expectEqual(@as(u8, 5), gamePakAccessCycles(u16, .nonsequential, 0, 0));
    try std.testing.expectEqual(@as(u8, 3), gamePakAccessCycles(u16, .sequential, 0, 0));
    try std.testing.expectEqual(@as(u8, 8), gamePakAccessCycles(u32, .nonsequential, 0, 0));
    try std.testing.expectEqual(@as(u8, 6), gamePakAccessCycles(u32, .sequential, 0, 0));
}

test "WAITCNT independently selects first and subsequent wait states" {
    const first_cycles = [_]u8{ 5, 4, 3, 9 };
    for (first_cycles, 0..) |cycles, select| {
        const waitcnt = @as(u16, @intCast(select)) << 2;
        try std.testing.expectEqual(cycles, gamePakAccessCycles(u16, .nonsequential, waitcnt, 0));
        try std.testing.expectEqual(cycles + 3, gamePakAccessCycles(u32, .nonsequential, waitcnt, 0));
    }
    try std.testing.expectEqual(@as(u8, 5), gamePakAccessCycles(u32, .nonsequential, 0x18, 0));
    try std.testing.expectEqual(@as(u8, 4), gamePakAccessCycles(u32, .sequential, 0x18, 0));
}

test "Game Pak prefetch caps at eight halfwords and discards a redirected stream" {
    var fifo: CartridgePrefetch = .{};
    const base: u32 = 0x0800_0100;
    try std.testing.expectEqual(@as(u8, 8), fifo.fetch(u32, base, .nonsequential, 8, 0, 0));
    fifo.advance(100);
    try std.testing.expectEqual(@as(u8, 24), fifo.progress);
    try std.testing.expectEqual(@as(u8, 1), fifo.fetch(u32, base + 4, .sequential, 8, 0, 0));
    try std.testing.expectEqual(@as(u8, 8), fifo.fetch(u32, base, .nonsequential, 8, 0, 0));
    fifo.advance(2);
    try std.testing.expectEqual(@as(u8, 1), fifo.stop());
    try std.testing.expectEqual(@as(u8, 0), fifo.stop());
}
