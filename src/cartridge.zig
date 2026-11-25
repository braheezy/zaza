const std = @import("std");
const zaza = @import("libzaza");
const Machine = @import("libzaza").Emulator;
const save_file = @import("save_file.zig");

pub const Options = struct {
    bios_path: ?[]const u8 = null,
    boot: bool = false,
    save: save_file.Options = .{},

    pub fn take(self: *Options, args: *[]const [:0]const u8) !bool {
        if (try self.save.take(args)) return true;
        if (args.len == 0) return false;
        if (std.mem.eql(u8, args.*[0], "--bios")) {
            if (args.len < 2 or self.bios_path != null) return error.InvalidArguments;
            self.bios_path = args.*[1];
            args.* = args.*[2..];
        } else if (std.mem.eql(u8, args.*[0], "--boot")) {
            self.boot = true;
            args.* = args.*[1..];
        } else return false;
        return true;
    }

    pub fn start(self: Options, machine: *Machine, io: std.Io, allocator: std.mem.Allocator, rom: []const u8) !?save_file.Session {
        try machine.init(rom, try self.emulatorOptions(io, allocator));
        return self.save.open(io, allocator, machine.saveMemory());
    }

    pub fn emulatorOptions(self: Options, io: std.Io, arena: std.mem.Allocator) !zaza.Options {
        return .{
            .bios = if (self.bios_path) |path| try loadBios(io, arena, path) else zaza.bundled_bios,
            .boot = if (self.boot) .bios else .cartridge,
        };
    }
};
fn loadBios(io: std.Io, arena: std.mem.Allocator, path: []const u8) !*const [@sizeOf(zaza.Bios)]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(@sizeOf(zaza.Bios) + 1),
    );
    if (bytes.len != @sizeOf(zaza.Bios)) return error.InvalidBiosSize;
    return bytes[0..@sizeOf(zaza.Bios)];
}

pub fn loadRom(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(zaza.max_rom_size + 1));
    if (rom.len < 8) return error.RomTooShort;
    if (rom.len > zaza.max_rom_size) return error.RomTooLarge;
    return rom;
}
