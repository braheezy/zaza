const std = @import("std");
const ini = @import("ini");
const Config = @This();

pub const Action = enum { showFps, quit };
const Section = enum { other, settings, shortcuts };
/// Physical key names accepted in zaza.ini.
pub const Key = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    zero,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_0,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal,
    kp_comma,
    kp_equal,
    kp_enter,

    enter,
    escape,
    tab,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_super,
    right_super,
    menu,
    num_lock,
    caps_lock,
    print,
    scroll_lock,
    pause,
    delete,
    home,
    end,
    page_up,
    page_down,
    insert,
    left,
    right,
    up,
    down,
    backspace,
    space,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,
    grave,

    iso_backslash,
    international1,
    international2,
    international3,
    international4,
    international5,
    lang1,
    lang2,

    unknown,
};

pub const Modifiers = struct { ctrl: bool = false, shift: bool = false, alt: bool = false, meta: bool = false };

const Shortcut = struct {
    key: Key,
    mods: Modifiers = .{},

    fn parse(text: []const u8) !?Shortcut {
        if (text.len == 0) return null;
        var parts = std.mem.splitScalar(u8, text, '+');
        var mods: Modifiers = .{};
        while (parts.next()) |part| {
            const token = std.mem.trim(u8, part, " \t");
            if (parts.peek() == null) {
                if (std.ascii.eqlIgnoreCase(token, "Esc")) return .{ .key = .escape, .mods = mods };
                if (token.len == 1 and std.ascii.isDigit(token[0])) return .{ .key = @enumFromInt(@intFromEnum(Key.zero) + @as(usize, token[0] - '0')), .mods = mods };
                inline for (std.meta.fields(Key)) |field| {
                    if (std.ascii.eqlIgnoreCase(token, field.name)) return .{ .key = @enumFromInt(field.value), .mods = mods };
                }
                return error.InvalidShortcut;
            }
            const flag = if (std.ascii.eqlIgnoreCase(token, "Ctrl"))
                &mods.ctrl
            else if (std.ascii.eqlIgnoreCase(token, "Shift"))
                &mods.shift
            else if (std.ascii.eqlIgnoreCase(token, "Alt"))
                &mods.alt
            else if (std.ascii.eqlIgnoreCase(token, "Meta") or std.ascii.eqlIgnoreCase(token, "Cmd"))
                &mods.meta
            else
                return error.InvalidShortcut;
            if (flag.*) return error.InvalidShortcut;
            flag.* = true;
        }
        return error.InvalidShortcut;
    }
};

show_fps: bool = false,
shortcuts: std.EnumArray(Action, ?Shortcut) = .init(.{
    .showFps = .{ .key = .f3 },
    .quit = .{ .key = .escape },
}),

pub fn action(self: *const Config, key: Key, held: Modifiers) ?Action {
    inline for (std.meta.tags(Action)) |tag| {
        if (self.shortcuts.get(tag)) |binding| {
            if (binding.key == key and std.meta.eql(binding.mods, held)) return tag;
        }
    }
    return null;
}

pub fn load(io: std.Io, allocator: std.mem.Allocator) !Config {
    const file = std.Io.Dir.cwd().openFile(io, "zaza.ini", .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return parse(allocator, &reader.interface);
}

fn parse(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Config {
    var parser = ini.parse(allocator, reader, ";#");
    defer parser.deinit();
    var config: Config = .{};
    var section: Section = .other;
    while (try parser.next()) |record| switch (record) {
        .section => |name| section = if (std.mem.eql(u8, name, "ports.qt")) .settings else if (std.mem.eql(u8, name, "shortcutKey")) .shortcuts else .other,
        .property => |kv| switch (section) {
            .settings => if (std.mem.eql(u8, kv.key, "showFps")) {
                config.show_fps = if (std.mem.eql(u8, kv.value, "1")) true else if (std.mem.eql(u8, kv.value, "0")) false else return error.InvalidShowFps;
            },
            .shortcuts => if (std.meta.stringToEnum(Action, kv.key)) |tag| {
                config.shortcuts.set(tag, try Shortcut.parse(kv.value));
            },
            .other => {},
        },
        .enumeration => {},
    };
    if (config.shortcuts.get(.showFps)) |fps| {
        if (config.shortcuts.get(.quit)) |quit| {
            if (std.meta.eql(fps, quit)) return error.DuplicateShortcut;
        }
    }
    return config;
}

test "mGBA-style project settings match exact shortcuts and allow unbinding" {
    var reader = std.Io.Reader.fixed("[ports.qt]\nshowFps=1\n[shortcutKey]\nshowFps=Ctrl+Shift+F4\nquit=\n");
    const config = try parse(std.testing.allocator, &reader);
    try std.testing.expect(config.show_fps);
    var mods: Modifiers = .{};
    try std.testing.expectEqual(null, config.action(.escape, mods));
    mods.ctrl = true;
    try std.testing.expectEqual(null, config.action(.f4, mods));
    mods.shift = true;
    try std.testing.expectEqual(Action.showFps, config.action(.f4, mods).?);
}

test {
    _ = @import("fps.zig");
}
