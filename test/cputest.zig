const std = @import("std");
const Cpu = @import("cpu");
const chameleon = @import("chameleon");
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

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    var style = chameleon.initRuntimeFromEnviron(.{ .allocator = init.gpa }, init.environ_map);
    defer style.deinit();
    var report: Report = .{ .writer = &stdout.interface, .style = &style };

    const result = runSelection(init, args, directory, case_index, &report);
    try stdout.interface.flush();
    try result;
}

fn runSelection(
    init: std.process.Init,
    args: []const [:0]const u8,
    directory: std.Io.Dir,
    case_index: ?usize,
    report: *Report,
) !void {
    if (args.len >= 3) {
        const family = args[2];
        if (family.len == 0) return usage();
        for (family) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return usage();
        }
        const filename = try init.arena.allocator().print("{s}{s}", .{ family, suffix });
        _ = try inspectFile(directory, init.io, init.gpa, filename, case_index, report);
    } else {
        var iterator = directory.iterate();
        var total: usize = 0;
        while (try iterator.next(init.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
            total += try inspectFile(directory, init.io, init.gpa, entry.name, null, report);
        }
        if (total == 0) return error.NoVectorsFound;
    }
    if (case_index == null) try report.summary();
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

const TestBus = struct {
    transactions: Reader,
    failure: ?error{ InvalidVector, UnexpectedFetch } = null,

    pub fn fetch32(self: *TestBus, address: u32) u32 {
        if (self.failure != null) return 0;
        return self.expectFetch32(address) catch |err| {
            // Keep the CPU bus API infallible; report mismatches after the step.
            self.failure = err;
            return 0;
        };
    }

    fn expectFetch32(self: *TestBus, address: u32) !u32 {
        if (self.transactions.remaining.len == 0) return error.UnexpectedFetch;
        const entry = try self.transactions.words(6);
        if (entry[0] != 0) return error.UnexpectedFetch;
        if (entry[1] != 4) return error.UnexpectedFetch;
        if (entry[2] != address) return error.UnexpectedFetch;
        return entry[3];
    }

    fn finish(self: TestBus) !void {
        if (self.failure) |err| return err;
        if (self.transactions.remaining.len != 0) return error.MissingTransaction;
    }
};

test "vector bus replays a fetch and detects missing or wrong fetches" {
    const bytes = [_]u8{
        0, 0, 0, 0, // Instruction read.
        4, 0, 0, 0, // Width in bytes.
        8, 0, 0, 8, // Address 0x08000008.
        42, 0, 0, 0, // Returned word.
        0, 0, 0, 0, // Cycle metadata.
        0, 0, 0, 0, // Access metadata.
    };
    var bus: TestBus = .{ .transactions = .{ .remaining = &bytes } };
    try std.testing.expectError(error.MissingTransaction, bus.finish());
    try std.testing.expectEqual(@as(u32, 42), bus.fetch32(0x0800_0008));
    try bus.finish();
    _ = bus.fetch32(0x0800_000C);
    try std.testing.expectError(error.UnexpectedFetch, bus.finish());

    bus = .{ .transactions = .{ .remaining = &bytes } };
    _ = bus.fetch32(0x0800_0004);
    try std.testing.expectError(error.UnexpectedFetch, bus.finish());
}

fn physicalBanks(state: State) Cpu.BankedRegisters {
    return .{
        .fiq = state.fiq,
        .supervisor = state.supervisor,
        .abort = state.abort,
        .irq = state.irq,
        .undefined_instruction = state.undefined_instruction,
    };
}

fn visibleRegister(state: State, index: u4) u32 {
    var cpu: Cpu = .{
        .registers = state.registers[0..15].*,
        .banked = physicalBanks(state),
        .cpsr = state.cpsr,
    };
    return cpu.readRegister(index);
}

fn runSelectedVector(vector: Vector) !void {
    const mode_bits: u5 = @truncate(vector.initial.cpsr);
    switch (mode_bits) {
        0x10, 0x11, 0x12, 0x13, 0x17, 0x1B, 0x1F => {},
        else => return error.UnsupportedInstruction,
    }
    if (vector.initial.pipeline[0] != vector.opcode) return error.InvalidVector;
    var cpu: Cpu = .{
        .registers = vector.initial.registers[0..15].*,
        .banked = physicalBanks(vector.initial),
        .instruction_address = vector.initial.registers[15] -% 8,
        .cpsr = vector.initial.cpsr,
        .spsr = vector.initial.spsr,
        .pipeline = vector.initial.pipeline,
    };

    var bus: TestBus = .{ .transactions = .{ .remaining = vector.transactions } };
    try cpu.step(&bus);
    try bus.finish();

    if (!std.meta.eql(physicalBanks(vector.final), cpu.banked)) return error.BankMismatch;
    if (!std.mem.eql(u32, vector.final.registers[0..15], &cpu.registers)) {
        return error.RegisterMismatch;
    }
    // The fixture can retain low target bits in R15 even when its fetches are aligned.
    const expected_pc = vector.final.registers[15] & ~@as(u32, 3);
    if (expected_pc != cpu.instruction_address +% 8) return error.PcMismatch;
    if (vector.final.cpsr != cpu.cpsr) return error.CpsrMismatch;
    if (!std.mem.eql(u32, &vector.final.spsr, &cpu.spsr)) return error.SpsrMismatch;
    if (!std.mem.eql(u32, &vector.final.pipeline, &cpu.pipeline.?)) return error.PipelineMismatch;
}

const Report = struct {
    writer: *std.Io.Writer,
    style: *chameleon.RuntimeChameleon,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    column: usize = 0,

    fn single(self: *Report, family: []const u8, index: usize, vector: Vector) !void {
        try self.style.bold().cyan().print(self.writer, "{s}", .{family});
        try self.style.magenta().print(self.writer, " · case {d}\n", .{index});
        const failure = outcome(family, vector);
        const skipped_case = if (failure) |err| err == error.UnsupportedInstruction else false;
        if (skipped_case) {
            try self.style.yellow().print(self.writer, "  SKIP", .{});
            try self.writer.print("  Unsupported opcode 0x{x:0>8}\n", .{vector.opcode});
        } else if (failure) |err| {
            try self.style.red().print(self.writer, "  FAIL", .{});
            try self.writer.print("  {s} (opcode 0x{x:0>8})\n", .{ @errorName(err), vector.opcode });
        } else {
            try self.style.bold().green().print(self.writer, "  PASS", .{});
            if (std.mem.eql(u8, family, "arm_b_bl")) {
                const link = vector.opcode & (1 << 24) != 0;
                try self.style.cyan().print(self.writer, "  {s}: PC 0x{x:0>8} → 0x{x:0>8}\n", .{
                    if (link) "BL" else "B",
                    vector.initial.registers[15] -% 8,
                    vector.final.registers[15] -% 8,
                });
            } else if (std.mem.eql(u8, family, "arm_mrs")) {
                const destination: u4 = @truncate(vector.opcode >> 12);
                const status = if (vector.opcode & (1 << 22) != 0) "SPSR" else "CPSR";
                try self.style.cyan().print(self.writer, "  MRS r{d}, {s}\n", .{
                    destination, status,
                });
                try self.style.green().print(self.writer, "        r{d}: 0x{x:0>8} → 0x{x:0>8}\n", .{
                    destination,
                    visibleRegister(vector.initial, destination),
                    visibleRegister(vector.final, destination),
                });
            } else {
                if (std.mem.eql(u8, family, "arm_swi")) {
                    try self.style.cyan().print(self.writer, "  SWI #0x{x} → PC 0x{x:0>8}\n", .{
                        vector.opcode & 0xFF_FFFF, vector.final.registers[15] -% 8,
                    });
                } else if (std.mem.startsWith(u8, family, "arm_msr_")) {
                    const status = if (vector.opcode & (1 << 22) != 0) "SPSR" else "CPSR";
                    try self.style.cyan().print(self.writer, "  MSR {s} (opcode 0x{x:0>8})\n", .{
                        status, vector.opcode,
                    });
                } else {
                    try self.explainImmediate(vector);
                }
            }
        }

        if (failure) |err| {
            if (err != error.UnsupportedInstruction) return error.VectorMismatch;
        }
    }

    fn explainImmediate(self: *Report, vector: Vector) !void {
        const instruction = vector.opcode;
        const destination: u4 = @truncate(instruction >> 12);
        const condition: u4 = @truncate(instruction >> 28);
        const rotation: u4 = @truncate(instruction >> 8);
        const immediate: u8 = @truncate(instruction);
        const value = std.math.rotr(u32, immediate, @as(u5, rotation) * 2);
        var operand_buffer: [32]u8 = undefined;
        const operand = if (instruction & (1 << 25) != 0)
            try std.fmt.bufPrint(&operand_buffer, "#0x{x:0>8}", .{value})
        else blk: {
            const register: u4 = @truncate(instruction);
            const amount: u5 = @truncate(instruction >> 7);
            const kind: u2 = @truncate(instruction >> 5);
            const names = [_][]const u8{ "LSL", "LSR", "ASR", "ROR" };
            if (instruction & (1 << 4) != 0) {
                const shift_register: u4 = @truncate(instruction >> 8);
                break :blk try std.fmt.bufPrint(&operand_buffer, "r{d}, {s} r{d}", .{
                    register, names[kind], shift_register,
                });
            }
            if (amount == 0) {
                if (kind == 0) break :blk try std.fmt.bufPrint(&operand_buffer, "r{d}", .{register});
                if (kind == 3) break :blk try std.fmt.bufPrint(&operand_buffer, "r{d}, RRX", .{register});
            }
            break :blk try std.fmt.bufPrint(&operand_buffer, "r{d}, {s} #{d}", .{
                register, names[kind], if (amount == 0) @as(u6, 32) else amount,
            });
        };
        const conditions = [_][]const u8{
            "EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
            "HI", "LS", "GE", "LT", "GT", "LE", "AL", "reserved",
        };
        const condition_suffix = if (condition == 14) "" else conditions[condition];
        const opcode: u4 = @truncate(instruction >> 21);
        const mnemonics = [_][]const u8{
            "AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC",
            "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN",
        };
        const mnemonic = mnemonics[opcode];
        if (opcode >= 8 and opcode <= 11) {
            const source: u4 = @truncate(instruction >> 16);
            try self.style.cyan().print(self.writer, "  {s}{s} r{d}, {s}\n", .{
                mnemonic, condition_suffix, source, operand,
            });
            try self.style.green().print(self.writer, "        NZCV: {b:0>4} → {b:0>4}\n", .{
                vector.initial.cpsr >> 28, vector.final.cpsr >> 28,
            });
            return;
        }
        const flag_suffix = if (instruction & (1 << 20) != 0) "S" else "";
        if (opcode != 13 and opcode != 15) {
            const source: u4 = @truncate(instruction >> 16);
            try self.style.cyan().print(self.writer, "  {s}{s}{s} r{d}, r{d}, {s}\n", .{
                mnemonic, condition_suffix, flag_suffix, destination, source, operand,
            });
        } else {
            try self.style.cyan().print(self.writer, "  {s}{s}{s} r{d}, {s}\n", .{
                mnemonic, condition_suffix, flag_suffix, destination, operand,
            });
        }
        if (destination == 15) {
            try self.style.green().print(self.writer, "        PC: 0x{x:0>8} → 0x{x:0>8}\n", .{
                vector.initial.registers[15] -% 8,
                (vector.final.registers[15] & ~@as(u32, 3)) -% 8,
            });
            return;
        }
        try self.style.dim().print(self.writer, "        r{d}: 0x{x:0>8} → ", .{
            destination, visibleRegister(vector.initial, destination),
        });
        try self.style.green().print(self.writer, "0x{x:0>8}\n", .{
            visibleRegister(vector.final, destination),
        });
    }

    fn outcome(family: []const u8, vector: Vector) ?anyerror {
        // Only run families whose state and bus accesses the adapter can check.
        const supported_families = [_][]const u8{
            "arm_data_proc_immediate",
            "arm_data_proc_immediate_shift",
            "arm_data_proc_register_shift",
            "arm_b_bl",
            "arm_mrs",
            "arm_msr_imm",
            "arm_msr_reg",
            "arm_swi",
        };
        for (supported_families) |supported| {
            if (std.mem.eql(u8, family, supported)) {
                runSelectedVector(vector) catch |err| return err;
                return null;
            }
        }
        return error.UnsupportedInstruction;
    }

    fn record(self: *Report, family: []const u8, index: usize, vector: Vector) !void {
        if (outcome(family, vector)) |err| {
            if (err == error.UnsupportedInstruction) {
                self.skipped += 1;
                return;
            }
            self.failed += 1;
            try self.style.red().print(self.writer, "F", .{});
            try self.writer.print("  {s}[{d}]: {s}\n", .{ family, index, @errorName(err) });
            self.column = 0;
            try self.rerun(family, index);
        } else {
            self.passed += 1;
            try self.style.green().print(self.writer, ".", .{});
            self.column += 1;
            if (self.column == 72) try self.endLine();
        }
    }

    fn endLine(self: *Report) !void {
        if (self.column != 0) try self.writer.writeByte('\n');
        self.column = 0;
    }

    fn rerun(self: *Report, family: []const u8, index: usize) !void {
        try self.writer.print("  Rerun: zig build cputest -- {s} --case {d}\n", .{ family, index });
    }

    fn summary(self: *Report) !void {
        try self.endLine();
        const total = self.passed + self.failed + self.skipped;
        try self.style.green().print(self.writer, "{d} passed ({d:.2}%)", .{
            self.passed, percentage(self.passed, total),
        });
        try self.writer.writeAll(" · ");
        try self.style.red().print(self.writer, "{d} failed ({d:.2}%)", .{
            self.failed, percentage(self.failed, total),
        });
        try self.writer.writeAll(" · ");
        try self.style.yellow().print(self.writer, "{d} skipped ({d:.2}%)", .{
            self.skipped, percentage(self.skipped, total),
        });
        try self.writer.writeByte('\n');
        if (self.failed != 0) return error.VectorMismatch;
    }
};

fn percentage(count: usize, total: usize) f64 {
    if (total == 0) return 0;
    return 100 * @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total));
}

fn inspectFile(
    directory: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    filename: []const u8,
    case_index: ?usize,
    report: *Report,
) !usize {
    return inspectFileInner(directory, io, allocator, filename, case_index, report) catch |err| {
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
    report: *Report,
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
        try report.single(family, selected, vector);
        return 1;
    }
    const skipped_before = report.skipped;
    for (0..count) |index| {
        const vector = Vector.decode(&reader) catch |err| {
            std.debug.print("{s}[{d}]: {s}\n", .{ family, index, @errorName(err) });
            return err;
        };
        try report.record(family, index, vector);
    }
    try reader.finish();
    const skipped = report.skipped - skipped_before;
    if (skipped != 0) {
        try report.endLine();
        try report.style.yellow().print(report.writer, "S", .{});
        try report.writer.print("  {s}: {d} unsupported cases\n", .{ family, skipped });
    }
    return count;
}
