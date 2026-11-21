const std = @import("std");

pub const Access = enum { nonsequential, sequential };

// Window 0 at WAITCNT reset, with prefetch off. These costs include the transfer cycle.
const first_halfword_cycles = 5;
const next_halfword_cycles = 3;

pub fn gamePak0AccessCycles(comptime T: type, access: Access) u8 {
    comptime std.debug.assert(T == u16 or T == u32);
    const first: u8 = switch (access) {
        .nonsequential => first_halfword_cycles,
        .sequential => next_halfword_cycles,
    };
    // A word uses two halfword transfers on the 16-bit cartridge bus.
    return first + if (T == u32) @as(u8, next_halfword_cycles) else 0;
}

test "Game Pak window 0 charges each halfword of a word access" {
    try std.testing.expectEqual(@as(u8, 5), gamePak0AccessCycles(u16, .nonsequential));
    try std.testing.expectEqual(@as(u8, 3), gamePak0AccessCycles(u16, .sequential));
    try std.testing.expectEqual(@as(u8, 8), gamePak0AccessCycles(u32, .nonsequential));
    try std.testing.expectEqual(@as(u8, 6), gamePak0AccessCycles(u32, .sequential));
}
