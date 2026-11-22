const std = @import("std");
const cartridge = @import("cartridge.zig");
pub const std_options = @import("logging.zig").options;

pub fn main(init: std.process.Init) !void {
    try @import("logging.zig").load(init.io, init.arena.allocator());
    var args = (try init.minimal.args.toSlice(init.arena.allocator()))[1..];
    var options: cartridge.Options = .{};
    var volume: u8 = 30;
    while (args.len != 0) {
        if (try options.take(&args)) continue;
        if (std.mem.eql(u8, args[0], "--mute")) {
            volume = 0;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "--volume") and args.len >= 2) {
            volume = try std.fmt.parseInt(u8, args[1], 10);
            if (volume > 100) return error.InvalidVolume;
            args = args[2..];
        } else break;
    }
    if (args.len != 1 or std.mem.startsWith(u8, args[0], "-")) {
        std.debug.print("Usage: zaza [--bios file] [--boot] [--save file] [--save-type type] [--mute | --volume 0..100] <game.gba>\n", .{});
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return;
        return error.InvalidArguments;
    }
    try @import("desktop.zig").play(init, options, args[0], volume);
}
