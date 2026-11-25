//! Desktop save states. See docs/input.md for the version 1 format.
const std = @import("std");
const Emulator = @import("libzaza").Emulator;
const Bus = @TypeOf(@as(Emulator, undefined).machine.bus);
const Audio = @TypeOf(@as(Bus, undefined).audio);
const Store = @This();
const Hash = std.crypto.hash.Blake3;
const magic = "ZAZAST\x00\x01";
pub const slots = 4; // Quick plus three numbered slots.
const names = [slots][]const u8{ "Quick.state", "1.state", "2.state", "3.state" };

directory: []const u8,
identity: [32]u8,
occupied: [slots]bool,

pub fn init(arena: std.mem.Allocator, io: std.Io, root: []const u8, machine: *Emulator, kind: @import("libzaza").SaveMemory.Kind) !Store {
    const bus = &machine.machine.bus;
    var hash = Hash.init(.{});
    hash.update(bus.bios.?);
    hash.update(&.{@intFromEnum(kind)});
    hash.update(bus.rom);
    var id: [32]u8 = undefined;
    hash.final(&id);
    const directory = try std.fmt.allocPrint(arena, "{s}/{x}", .{ root, &id });
    var store: Store = .{ .directory = directory, .identity = id, .occupied = @splat(false) };
    if (std.Io.Dir.cwd().openDir(io, directory, .{})) |dir| {
        defer dir.close(io);
        for (names, 0..) |name, i| {
            dir.access(io, name, .{}) catch continue;
            store.occupied[i] = true;
        }
    } else |_| {}
    return store;
}

pub fn save(self: *Store, gpa: std.mem.Allocator, io: std.Io, slot: usize, machine: *Emulator) !void {
    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    try transfer(&data.writer, &machine.machine);
    var digest: [32]u8 = undefined;
    Hash.hash(data.written(), &digest, .{});
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, self.directory, .{});
    defer dir.close(io);
    var file = try dir.createFileAtomic(io, names[slot], .{ .replace = true });
    defer file.deinit(io);
    for ([_][]const u8{ magic, &self.identity, &digest, data.written() }) |part| {
        try file.file.writeStreamingAll(io, part);
    }
    try file.file.sync(io);
    try file.replace(io);
    self.occupied[slot] = true;
}

pub fn load(self: *Store, gpa: std.mem.Allocator, io: std.Io, slot: usize, machine: *Emulator) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, self.directory, .{});
    defer dir.close(io);
    const data = try dir.readFileAlloc(io, names[slot], gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(data);
    var reader = std.Io.Reader.fixed(data);
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.UnsupportedStateVersion;
    if (!std.mem.eql(u8, try reader.take(32), &self.identity)) return error.DifferentCartridge;
    const expected = try reader.take(32);
    var digest: [32]u8 = undefined;
    Hash.hash(data[reader.seek..], &digest, .{});
    if (!std.mem.eql(u8, expected, &digest)) return error.DamagedState;
    const next = try gpa.create(Emulator);
    defer gpa.destroy(next);
    next.* = machine.*; // Preserve this process's ROM, BIOS and audio sink.
    try transfer(&reader, &next.machine);
    if (reader.seek != data.len) return error.InvalidState;
    const old = machine.saveMemory();
    const restored = next.saveMemory();
    restored.dirty = old.dirty or !std.mem.eql(u8, old.bytes(), restored.bytes());
    machine.* = next.*;
}

pub fn remove(self: *Store, io: std.Io, slot: usize) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, self.directory, .{});
    defer dir.close(io);
    try dir.deleteFile(io, names[slot]);
    self.occupied[slot] = false;
}

// Encode fields in declaration order without native padding or host pointers.
// Instantiating this with a Reader or Writer keeps the two layouts identical.
fn transfer(stream: anytype, value: anytype) !void {
    const T = @TypeOf(value.*);
    const reading = @TypeOf(stream) == *std.Io.Reader;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (comptime !(T == Bus and (std.mem.eql(u8, f.name, "rom") or std.mem.eql(u8, f.name, "bios"))) and
                !(T == Audio and std.mem.eql(u8, f.name, "capture")))
                try transfer(stream, &@field(value.*, f.name));
        },
        .array => |a| if (a.child == u8) {
            if (reading) try stream.readSliceAll(value) else try stream.writeAll(value);
        } else {
            for (value) |*item| try transfer(stream, item);
        },
        .int => |info| {
            const Wire = @Int(info.signedness, @divTrunc(info.bits + 7, 8) * 8);
            if (reading) {
                value.* = std.math.cast(T, try stream.takeInt(Wire, .little)) orelse return error.InvalidState;
            } else try stream.writeInt(Wire, value.*, .little);
        },
        .bool => if (reading) {
            value.* = switch (try stream.takeByte()) {
                0 => false,
                1 => true,
                else => return error.InvalidState,
            };
        } else try stream.writeByte(@intFromBool(value.*)),
        .@"enum" => {
            var tag: std.meta.Tag(T) = undefined;
            if (!reading) tag = @intFromEnum(value.*);
            try transfer(stream, &tag);
            if (reading) value.* = std.enums.fromInt(T, tag) orelse return error.InvalidState;
        },
        .optional => {
            var present = if (reading) false else value.* != null;
            try transfer(stream, &present);
            if (reading) value.* = if (present) @as(@typeInfo(T).optional.child, undefined) else null;
            if (present) try transfer(stream, &value.*.?);
        },
        else => @compileError("Missing state encoding for " ++ @typeName(T)),
    }
}
