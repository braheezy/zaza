const std = @import("std");

pub const Buttons = u10;

pub const Button = enum(u4) {
    a,
    b,
    select,
    start,
    right,
    left,
    up,
    down,
    r,
    l,

    pub fn mask(self: Button) Buttons {
        return @as(Buttons, 1) << @intFromEnum(self);
    }
};

pub const Change = struct {
    frame: u32,
    buttons: Buttons,
};

/// Each row is a zero-based frame number followed by button names or "none".
/// The caller owns the result. Frame numbers must increase strictly.
pub fn parseScript(allocator: std.mem.Allocator, source: []const u8) ![]Change {
    var changes: std.ArrayList(Change) = .empty;
    errdefer changes.deinit(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const end = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        var words = std.mem.tokenizeAny(u8, line[0..end], " \t\r");
        const token = words.next() orelse continue;
        const change = parseLine(token, &words) catch |err| {
            std.log.err("input line {d}: {s}", .{ line_number, @errorName(err) });
            return err;
        };
        if (changes.items.len != 0) {
            if (change.frame <= changes.items[changes.items.len - 1].frame) {
                std.log.err("input line {d}: frame numbers must increase", .{line_number});
                return error.UnorderedInputFrames;
            }
        }
        try changes.append(allocator, change);
    }
    return changes.toOwnedSlice(allocator);
}

fn parseLine(frame_word: []const u8, words: *std.mem.TokenIterator(u8, .any)) !Change {
    const frame = std.fmt.parseInt(u32, frame_word, 10) catch return error.InvalidInputFrame;
    return .{ .frame = frame, .buttons = try parseButtons(words) };
}

pub fn parseButtons(words: *std.mem.TokenIterator(u8, .any)) !Buttons {
    const first = words.next() orelse return error.MissingButtons;
    if (std.ascii.eqlIgnoreCase(first, "none")) {
        if (words.next() != null) return error.InvalidButtons;
        return 0;
    }
    var buttons = try buttonMask(first);
    while (words.next()) |word| {
        const mask = try buttonMask(word);
        if (buttons & mask != 0) return error.DuplicateButton;
        buttons |= mask;
    }
    return buttons;
}

fn buttonMask(word: []const u8) !Buttons {
    inline for (std.meta.fields(Button)) |field| {
        if (std.ascii.eqlIgnoreCase(word, field.name)) {
            const button: Button = @enumFromInt(field.value);
            return button.mask();
        }
    }
    return error.UnknownButton;
}

pub const Replay = struct {
    remaining: []const Change,
    held: Buttons = 0,

    /// Call once for each frame, in order, beginning at frame zero.
    pub fn buttonsForFrame(self: *Replay, frame: u32) Buttons {
        if (self.remaining.len != 0) {
            std.debug.assert(self.remaining[0].frame >= frame);
            if (self.remaining[0].frame == frame) {
                self.held = self.remaining[0].buttons;
                self.remaining = self.remaining[1..];
            }
        }
        return self.held;
    }
};

test "script rows replace the held mask at the specified frames" {
    const changes = try parseScript(std.testing.allocator, "1 Right a # chord\r\n3 L\n5 none");
    defer std.testing.allocator.free(changes);
    var replay: Replay = .{ .remaining = changes };
    for ([_]Buttons{ 0, 0x11, 0x11, 0x200, 0x200, 0 }, 0..) |expected, frame| {
        try std.testing.expectEqual(expected, replay.buttonsForFrame(@intCast(frame)));
    }
}

/// Collect host transitions until the next emulated frame samples them.
pub const LiveKeys = struct {
    held: Buttons = 0,
    pressed_since_sample: Buttons = 0,

    pub fn press(self: *LiveKeys, button: Button) void {
        const mask = button.mask();
        self.pressed_since_sample |= mask & ~self.held;
        self.held |= mask;
    }

    pub fn release(self: *LiveKeys, button: Button) void {
        self.held &= ~button.mask();
    }

    pub fn sample(self: *LiveKeys) Buttons {
        const buttons = self.held | self.pressed_since_sample;
        self.pressed_since_sample = 0;
        return buttons;
    }
};

test "a quick tap reaches one frame and focus loss clears pending and held keys" {
    var keys: LiveKeys = .{};
    keys.press(.a);
    keys.release(.a);
    try std.testing.expectEqual(Button.a.mask(), keys.sample());
    try std.testing.expectEqual(@as(Buttons, 0), keys.sample());
    keys.press(.left);
    try std.testing.expectEqual(Button.left.mask(), keys.sample());
    try std.testing.expectEqual(Button.left.mask(), keys.sample());
    keys.press(.b);
    keys = .{};
    try std.testing.expectEqual(@as(Buttons, 0), keys.sample());
}
