const std = @import("std");

pub const Access = enum { nonsequential, sequential };

pub fn gamePak0AccessCycles(comptime T: type, access: Access, waitcnt: u16) u8 {
    comptime std.debug.assert(T == u16 or T == u32);
    const first_select: u2 = @truncate(waitcnt >> 2);
    const first_wait = [_]u8{ 4, 3, 2, 8 };
    const next_wait: u8 = if (waitcnt & (1 << 4) != 0) 1 else 2;
    // WAITCNT selects wait cycles; each halfword also takes one transfer cycle.
    const first_cycles = 1 + if (access == .nonsequential) first_wait[first_select] else next_wait;
    const next_cycles = 1 + next_wait;
    return first_cycles + if (T == u32) next_cycles else 0;
}

test "Game Pak window 0 charges each halfword of a word access" {
    try std.testing.expectEqual(@as(u8, 5), gamePak0AccessCycles(u16, .nonsequential, 0));
    try std.testing.expectEqual(@as(u8, 3), gamePak0AccessCycles(u16, .sequential, 0));
    try std.testing.expectEqual(@as(u8, 8), gamePak0AccessCycles(u32, .nonsequential, 0));
    try std.testing.expectEqual(@as(u8, 6), gamePak0AccessCycles(u32, .sequential, 0));
}

test "WAITCNT independently selects first and subsequent wait states" {
    const first_cycles = [_]u8{ 5, 4, 3, 9 };
    for (first_cycles, 0..) |cycles, select| {
        const waitcnt = @as(u16, @intCast(select)) << 2;
        try std.testing.expectEqual(cycles, gamePak0AccessCycles(u16, .nonsequential, waitcnt));
        try std.testing.expectEqual(cycles + 3, gamePak0AccessCycles(u32, .nonsequential, waitcnt));
    }
    try std.testing.expectEqual(@as(u8, 5), gamePak0AccessCycles(u32, .nonsequential, 0x18));
    try std.testing.expectEqual(@as(u8, 4), gamePak0AccessCycles(u32, .sequential, 0x18));
}
