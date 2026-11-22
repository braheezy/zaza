//! Process-wide frontend settings, initialized once before any worker threads start.
const std = @import("std");
const ini = @import("ini");

pub const options: std.Options = .{ .log_level = .debug, .logFn = emit };

const Filter = struct {
    default: ?u7 = null,
    categories: std.StringHashMapUnmanaged(u7) = .empty,
};

var active: Filter = .{};

/// The allocator owns category names until process exit.
pub fn load(io: std.Io, arena: std.mem.Allocator) !void {
    const file = std.Io.Dir.cwd().openFile(io, "zaza.ini", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var parser = ini.parse(arena, &reader.interface, ";#");
    defer parser.deinit();
    var filter: Filter = .{};
    var settings = false;
    while (try parser.next()) |record| switch (record) {
        .section => |name| settings = std.mem.eql(u8, name, "ports.qt"),
        .property => |kv| {
            if (!settings) continue;
            if (std.mem.eql(u8, kv.key, "logLevel")) {
                filter.default = try parseMask(kv.value);
            } else if (std.mem.startsWith(u8, kv.key, "logLevel.")) {
                const name = kv.key["logLevel.".len..];
                if (name.len == 0) return error.InvalidLogCategory;
                try filter.categories.put(arena, try arena.dupe(u8, name), try parseMask(kv.value));
            }
        },
        .enumeration => {},
    };
    active = filter;
}

fn parseMask(text: []const u8) !u7 {
    return std.fmt.parseInt(u7, text, 0) catch error.InvalidLogMask;
}

fn emit(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const guest = scope == .gba or scope == .gba_fatal;
    const category = if (guest) "gba.debug" else @tagName(scope);
    const bit: u7 = if (scope == .gba_fatal) 1 else switch (level) {
        .err => 2,
        .warn => 4,
        .info => 8,
        .debug => 16,
    };
    if (active.categories.get(category) orelse active.default) |mask| {
        if (mask & bit == 0) return;
    } else if (!guest and @intFromEnum(level) > @intFromEnum(std.log.default_level)) return;
    std.log.defaultLog(level, scope, format, args);
}
