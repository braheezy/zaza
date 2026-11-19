const std = @import("std");
const suffix = ".json.bin";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 and args.len != 3 and args.len != 5) return usage();
    const case_index: ?usize = if (args.len == 5) blk: {
        if (!std.mem.eql(u8, args[3], "--case")) return usage();
        break :blk std.fmt.parseInt(usize, args[4], 10) catch return usage();
    } else null;
    var directory = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
    defer directory.close(init.io);

    if (args.len >= 3) {
        const family = args[2];
        if (family.len == 0) return usage();
        for (family) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return usage();
        }
        const filename = try init.arena.allocator().print("{s}{s}", .{ family, suffix });
        _ = try inspectFile(directory, init.io, init.gpa, filename, case_index);
    } else {
        var iterator = directory.iterate();
        var total: usize = 0;
        while (try iterator.next(init.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
            total += try inspectFile(directory, init.io, init.gpa, entry.name, null);
        }
        if (total == 0) return error.NoVectorsFound;
        std.debug.print("Decoded {d} cases total (no CPU execution).\n", .{total});
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print("Usage: zig build cputest -- [family [--case index]]\n", .{});
    return error.InvalidArguments;
}

const State = struct {
    registers: [16]u32,
    fiq: [7]u32,
    supervisor: [2]u32,
    abort: [2]u32,
    irq: [2]u32,
    undefined_instruction: [2]u32,
    cpsr: u32,
    spsr: [5]u32,
    pipeline: [2]u32,
    access: u32,

    fn decode(reader: *Reader) !State {
        var section = try reader.section();
        _ = try section.word(); // State section tag.
        const state: State = .{
            .registers = try section.words(16),
            .fiq = try section.words(7),
            .supervisor = try section.words(2),
            .abort = try section.words(2),
            .irq = try section.words(2),
            .undefined_instruction = try section.words(2),
            .cpsr = try section.word(),
            .spsr = try section.words(5),
            .pipeline = try section.words(2),
            .access = try section.word(),
        };
        try section.finish();
        return state;
    }
};

const Vector = struct {
    initial: State,
    final: State,
    opcode: u32,
    base_address: u32,
    transaction_count: u32,
    transactions: []const u8,

    fn decode(reader: *Reader) !Vector {
        var record = try reader.section();
        const initial = try State.decode(&record);
        const final = try State.decode(&record);
        var transactions = try record.section();
        if (try transactions.word() != 3) return error.InvalidVector;
        const count = try transactions.word();
        const bytes = transactions.remaining;
        if (@as(u64, count) * 24 != bytes.len) return error.InvalidVector;
        var opcode_section = try record.section();
        _ = try opcode_section.word(); // Opcode section tag.
        const opcode = try opcode_section.word();
        const base_address = try opcode_section.word();
        try opcode_section.finish();
        try record.finish();
        return .{
            .initial = initial,
            .final = final,
            .opcode = opcode,
            .base_address = base_address,
            .transaction_count = count,
            .transactions = bytes,
        };
    }
};

const Reader = struct {
    remaining: []const u8,

    fn word(self: *Reader) error{InvalidVector}!u32 {
        if (self.remaining.len < 4) return error.InvalidVector;
        const value = std.mem.readInt(u32, self.remaining[0..4], .little);
        self.remaining = self.remaining[4..];
        return value;
    }

    fn words(self: *Reader, comptime count: usize) ![count]u32 {
        var values: [count]u32 = undefined;
        for (&values) |*value| value.* = try self.word();
        return values;
    }

    fn section(self: *Reader) !Reader {
        const length = try self.word();
        if (length < 4) return error.InvalidVector;
        const payload_length = length - 4;
        if (payload_length > self.remaining.len) return error.InvalidVector;
        const payload = self.remaining[0..payload_length];
        self.remaining = self.remaining[payload_length..];
        return .{ .remaining = payload };
    }

    fn finish(self: Reader) !void {
        if (self.remaining.len != 0) return error.InvalidVector;
    }
};

fn inspectFile(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    case_index: ?usize,
) !usize {
    return inspectFileInner(directory, io, allocator, filename, case_index) catch |err| {
        std.debug.print("{s}: {s}\n", .{ filename, @errorName(err) });
        return err;
    };
}

fn inspectFileInner(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    case_index: ?usize,
) !usize {
    const bytes = try directory.readFileAlloc(io, filename, allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(bytes);
    var reader: Reader = .{ .remaining = bytes };
    if (try reader.word() != 0xD33DBAE0) return error.InvalidVector;
    const count = try reader.word();
    const family = filename[0 .. filename.len - suffix.len];
    if (case_index) |selected| {
        if (selected >= count) return error.CaseIndexOutOfRange;
        for (0..selected) |_| _ = try reader.section();
        const vector = try Vector.decode(&reader);
        std.debug.print("{s}[{d}]: opcode=0x{x:0>8} base=0x{x:0>8}, {d} transactions\n", .{
            family, selected, vector.opcode, vector.base_address, vector.transaction_count,
        });
        std.debug.print("  CPSR: 0x{x:0>8} -> 0x{x:0>8} (no CPU execution)\n", .{
            vector.initial.cpsr, vector.final.cpsr,
        });
        return 1;
    }
    for (0..count) |index| {
        _ = Vector.decode(&reader) catch |err| {
            std.debug.print("{s}[{d}]: {s}\n", .{ family, index, @errorName(err) });
            return err;
        };
    }
    try reader.finish();
    std.debug.print("{s}: {d} cases decoded (no CPU execution)\n", .{ family, count });
    return count;
}
