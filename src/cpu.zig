const std = @import("std");

const Mode = enum(u5) {
    user = 0x10,
    fiq = 0x11,
    irq = 0x12,
    supervisor = 0x13,
    abort = 0x17,
    undefined_instruction = 0x1B,
    system = 0x1F,
};

const Cpu = @This();

registers: [15]u32 = @splat(0),
instruction_address: u32 = 0,
// Current instruction first, then the next one. Null until the initial refill.
pipeline: ?[2]u32 = null,
cpsr: u32 = 0xD3, // Supervisor mode, ARM state, IRQ and FIQ masked.

const stack_pointer: u4 = 13;
const link_register: u4 = 14;
const program_counter: u4 = 15;
const thumb_bit: u32 = 1 << 5;
const flags_shift = 28;
const flags_mask: u32 = 0xF << flags_shift;

const Flags = packed struct(u4) {
    overflow: bool = false,
    carry: bool = false,
    zero: bool = false,
    negative: bool = false,
};

pub fn refillArmPipeline(self: *Cpu, bus: anytype) void {
    std.debug.assert(self.cpsr & thumb_bit == 0);
    std.debug.assert(self.instruction_address & 3 == 0);
    const current = bus.fetch32(self.instruction_address);
    const next = bus.fetch32(self.instruction_address +% 4);
    self.pipeline = .{ current, next };
}

pub fn step(self: *Cpu, bus: anytype) error{ PipelineNotReady, UnsupportedInstruction }!void {
    if (self.cpsr & thumb_bit != 0) return error.UnsupportedInstruction;
    const queued = self.pipeline orelse return error.PipelineNotReady;
    const instruction = queued[0];
    const condition: u4 = @truncate(instruction >> 28);
    const destination: u4 = @truncate(instruction >> 12);

    if (condition == 0xF) return error.UnsupportedInstruction;
    const is_move = instruction & 0x0FFF_0000 == 0x03A0_0000;
    const is_add = instruction & 0x0FE0_0000 == 0x0280_0000;
    const source: u4 = @truncate(instruction >> 16);
    if (is_add) {
        if (source >= 8) return error.UnsupportedInstruction;
        if (destination >= 8) return error.UnsupportedInstruction;
    } else {
        if (!is_move) return error.UnsupportedInstruction;
        if (destination == program_counter) return error.UnsupportedInstruction;
    }

    if (conditionPassed(condition, self.readFlags())) {
        const immediate: u8 = @truncate(instruction);
        const rotation: u4 = @truncate(instruction >> 8);
        const value = std.math.rotr(u32, immediate, @as(u5, rotation) * 2);
        if (is_add) {
            const left = self.readRegister(source);
            const sum, const carry = @addWithOverflow(left, value);
            self.writeGeneralRegister(destination, sum);
            if (instruction & (1 << 20) != 0) {
                self.writeFlags(.{
                    .negative = sum >> 31 != 0,
                    .zero = sum == 0,
                    .carry = carry != 0,
                    .overflow = ((left ^ sum) & (value ^ sum)) >> 31 != 0,
                });
            }
        } else {
            self.writeGeneralRegister(destination, value);
        }
    }
    _ = self.advanceArmPipeline(bus);
}

fn advanceArmPipeline(self: *Cpu, bus: anytype) u32 {
    std.debug.assert(self.cpsr & thumb_bit == 0);
    const queued = self.pipeline.?;
    const fetched = bus.fetch32(self.instruction_address +% 8);
    self.pipeline = .{ queued[1], fetched };
    self.instruction_address +%= 4;
    return queued[0];
}

fn readFlags(self: *const Cpu) Flags {
    const bits: u4 = @truncate(self.cpsr >> flags_shift);
    return @bitCast(bits);
}

fn writeFlags(self: *Cpu, flags: Flags) void {
    const bits: u4 = @bitCast(flags);
    self.cpsr = (self.cpsr & ~flags_mask) | (@as(u32, bits) << flags_shift);
}

fn conditionPassed(condition: u4, flags: Flags) bool {
    return switch (condition) {
        0x0 => flags.zero, // EQ
        0x1 => !flags.zero, // NE
        0x2 => flags.carry, // CS/HS
        0x3 => !flags.carry, // CC/LO
        0x4 => flags.negative, // MI
        0x5 => !flags.negative, // PL
        0x6 => flags.overflow, // VS
        0x7 => !flags.overflow, // VC
        0x8 => if (flags.carry) !flags.zero else false, // HI
        0x9 => if (flags.carry) flags.zero else true, // LS
        0xA => flags.negative == flags.overflow, // GE
        0xB => flags.negative != flags.overflow, // LT
        0xC => if (flags.zero) false else flags.negative == flags.overflow, // GT
        0xD => if (flags.zero) true else flags.negative != flags.overflow, // LE
        0xE => true, // AL
        0xF => false, // Reserved on ARMv4T; this predicate does not decode it.
    };
}

fn readRegister(self: *const Cpu, index: u4) u32 {
    if (index == program_counter) {
        const offset: u32 = if (self.cpsr & thumb_bit != 0) 4 else 8;
        return self.instruction_address +% offset;
    }
    return self.registers[index];
}

fn writeGeneralRegister(self: *Cpu, index: u4, value: u32) void {
    // PC writes must go through the control-flow path.
    std.debug.assert(index < program_counter);
    self.registers[index] = value;
}

fn mode(self: *Cpu) Mode {
    const mode_bits: u5 = @truncate(self.cpsr);
    return @fromBackingInt(mode_bits);
}

test "ARM pipeline refill and advance fetch words in address order" {
    const TestBus = struct {
        addresses: [3]u32 = @splat(0),
        fetch_count: usize = 0,

        fn fetch32(self: *@This(), address: u32) u32 {
            self.addresses[self.fetch_count] = address;
            self.fetch_count += 1;
            return address + 0x100;
        }
    };
    var bus: TestBus = .{};
    var cpu: Cpu = .{ .instruction_address = 0x0800_0000 };

    cpu.refillArmPipeline(&bus);
    try std.testing.expectEqual([2]u32{ 0x0800_0100, 0x0800_0104 }, cpu.pipeline.?);
    try std.testing.expectEqual(@as(usize, 2), bus.fetch_count);
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.advanceArmPipeline(&bus));
    try std.testing.expectEqual([2]u32{ 0x0800_0104, 0x0800_0108 }, cpu.pipeline.?);
    try std.testing.expectEqual(@as(u32, 0x0800_0004), cpu.instruction_address);
    try std.testing.expectEqual([3]u32{ 0x0800_0000, 0x0800_0004, 0x0800_0008 }, bus.addresses);
}

test "ARM step executes the queued MOV and fetches the next word" {
    const TestBus = struct {
        fetched_address: ?u32 = null,

        pub fn fetch32(self: *@This(), address: u32) u32 {
            self.fetched_address = address;
            return 0xE3A0_2000;
        }
    };
    var bus: TestBus = .{};
    var cpu: Cpu = .{
        .instruction_address = 0x0800_0000,
        .pipeline = .{ 0xE3A0_04FF, 0xE3A0_1000 },
    };

    try cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), cpu.registers[0]);
    try std.testing.expectEqual(@as(u32, 0xD3), cpu.cpsr);
    try std.testing.expectEqual(@as(?u32, 0x0800_0008), bus.fetched_address);
    try std.testing.expectEqual(@as(u32, 0x0800_0004), cpu.instruction_address);
    try std.testing.expectEqual([2]u32{ 0xE3A0_1000, 0xE3A0_2000 }, cpu.pipeline.?);
}

test "LR is stored, but reading PC derives a value" {
    var cpu: Cpu = .{ .instruction_address = 0x0800_0100 };

    cpu.writeGeneralRegister(Cpu.link_register, 0x0800_0104);
    try std.testing.expectEqual(@as(u32, 0x0800_0104), cpu.readRegister(14));
    try std.testing.expectEqual(@as(u32, 0x0800_0108), cpu.readRegister(15));
}

test "CPSR flags map to NZCV and writes preserve all other bits" {
    const lower_bits: u32 = 0x0567_89F3;
    for (0..16) |combination| {
        const bits: u4 = @intCast(combination);
        const expected: Flags = .{
            .negative = bits & 0b1000 != 0,
            .zero = bits & 0b0100 != 0,
            .carry = bits & 0b0010 != 0,
            .overflow = bits & 0b0001 != 0,
        };
        const cpsr = lower_bits | (@as(u32, bits) << 28);
        var cpu: Cpu = .{ .cpsr = cpsr ^ 0xF000_0000 };

        cpu.writeFlags(expected);
        try std.testing.expectEqual(cpsr, cpu.cpsr);
        try std.testing.expectEqual(expected, cpu.readFlags());
    }
}

test "ARM conditions across all NZCV combinations" {
    // Each mask is a truth table: bit i is the result for NZCV equal to i.
    const passing_flags = [16]u16{
        0xF0F0, 0x0F0F, 0xCCCC, 0x3333, // EQ, NE, CS, CC.
        0xFF00, 0x00FF, 0xAAAA, 0x5555, // MI, PL, VS, VC.
        0x0C0C, 0xF3F3, 0xAA55, 0x55AA, // HI, LS, GE, LT.
        0x0A05, 0xF5FA, 0xFFFF, 0x0000, // GT, LE, AL, reserved.
    };
    for (passing_flags, 0..) |mask, condition_index| {
        const condition: u4 = @intCast(condition_index);
        for (0..16) |combination| {
            const bits: u4 = @intCast(combination);
            const flags: Flags = @bitCast(bits);
            const expected = (mask >> bits) & 1 != 0;
            try std.testing.expectEqual(expected, conditionPassed(condition, flags));
        }
    }
}
