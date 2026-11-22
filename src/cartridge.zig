const std = @import("std");
const Bus = @import("bus.zig");
const Machine = @import("machine.zig");
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
        const bios = if (self.bios_path) |path| try loadBios(io, allocator, path) else bundled_bios;
        if (self.boot) machine.initBios(rom, bios) else machine.initCartridgeWithBios(rom, bios);
        return self.save.open(io, allocator, &machine.bus.save);
    }
};
fn loadBios(io: std.Io, arena: std.mem.Allocator, path: []const u8) !*const [Bus.bios_size_bytes]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(Bus.bios_size_bytes + 1),
    );
    if (bytes.len != Bus.bios_size_bytes) return error.InvalidBiosSize;
    return bytes[0..Bus.bios_size_bytes];
}

pub fn loadRom(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024 + 1));
    if (rom.len < 8) return error.RomTooShort;
    if (rom.len > 32 * 1024 * 1024) return error.RomTooLarge;
    return rom;
}

pub const bundled_bios = @embedFile("emibios");
comptime {
    @setEvalBranchQuota(2_000_000);
    if (bundled_bios.len != Bus.bios_size_bytes) @compileError("Invalid bundled BIOS size");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bundled_bios, &digest, .{});
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(&expected_buffer, "95e6c8a6c236ed8e2629bdb60bc75791434c4f08ca69ad2305e30ca3f3c29d1b") catch unreachable;
    if (!std.mem.eql(u8, &digest, expected)) @compileError("Bundled BIOS checksum mismatch");
}
