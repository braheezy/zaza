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
banked: BankedRegisters = .{},
instruction_address: u32 = 0,
// Current instruction first, then the next one. Null until the initial refill.
pipeline: ?[2]u32 = null,
cpsr: u32 = 0xD3, // Supervisor mode, ARM state, IRQ and FIQ masked.
// FIQ, Supervisor, Abort, IRQ, Undefined, in bank order.
spsr: [5]u32 = @splat(0),

pub const BankedRegisters = struct {
    fiq: [7]u32 = @splat(0),
    supervisor: [2]u32 = @splat(0),
    abort: [2]u32 = @splat(0),
    irq: [2]u32 = @splat(0),
    undefined_instruction: [2]u32 = @splat(0),
};

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
    if (instruction & 0x0FFF_FFF0 == 0x012F_FF10) {
        try self.executeArmBx(bus, instruction);
        return;
    }
    if (instruction >> 25 & 0b111 == 0b101) {
        const condition: u4 = @truncate(instruction >> 28);
        if (condition == 0xF) return error.UnsupportedInstruction;
        self.executeArmBranch(bus, instruction, condition);
        return;
    }
    // Decode status transfers before the ALU because their encodings overlap.
    if (instruction & 0x0FBF_0FFF == 0x010F_0000) {
        try self.executeArmMrs(instruction);
        _ = self.advanceArmPipeline(bus);
        return;
    }
    if (instruction & 0x0FB0_FFF0 == 0x0120_F000 or
        instruction & 0x0FB0_F000 == 0x0320_F000)
    {
        try self.executeArmMsr(instruction);
        _ = self.advanceArmPipeline(bus);
        return;
    }
    if (instruction >> 24 & 0xF == 0xF) {
        const condition: u4 = @truncate(instruction >> 28);
        if (condition == 0xF) return error.UnsupportedInstruction;
        self.executeArmSwi(bus, condition);
        return;
    }
    // Multiply encodings overlap the data-processing space.
    if (instruction & 0x0FC0_00F0 == 0x0000_0090 or instruction & 0x0F80_00F0 == 0x0080_0090) {
        try self.executeArmMultiply(instruction);
        _ = self.advanceArmPipeline(bus);
        return;
    }
    const decoded = try decodeArmDataProcessing(instruction);
    const redirect = self.executeArmDataProcessing(decoded);
    _ = self.advanceArmPipeline(bus);
    if (redirect) |target| {
        self.instruction_address = target & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    }
}

fn executeArmBx(self: *Cpu, bus: anytype, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;
    const source: u4 = @truncate(instruction);
    if (source == program_counter) return error.UnsupportedInstruction;
    const taken = conditionPassed(condition, self.readFlags());
    const target = if (taken) self.readRegister(source) else 0;
    // The old instruction stream still supplies the sequential ARM fetch.
    _ = self.advanceArmPipeline(bus);
    if (!taken) return;

    if (target & 1 != 0) {
        self.cpsr |= thumb_bit;
        self.instruction_address = target & ~@as(u32, 1);
        const current = bus.fetch16(self.instruction_address);
        const next = bus.fetch16(self.instruction_address +% 2);
        self.pipeline = .{ current, next };
    } else {
        self.instruction_address = target & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    }
}

fn executeArmMultiply(self: *Cpu, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 15) return error.UnsupportedInstruction;
    const left_register: u4 = @truncate(instruction);
    const right_register: u4 = @truncate(instruction >> 8);
    const lower_register: u4 = @truncate(instruction >> 12);
    const upper_register: u4 = @truncate(instruction >> 16);
    const long = instruction & (1 << 23) != 0;
    const accumulate = instruction & (1 << 21) != 0;
    // ARMv4T excludes PC and restricts destination aliases with Rm.
    if (left_register == program_counter or right_register == program_counter or
        upper_register == program_counter or upper_register == left_register)
    {
        return error.UnsupportedInstruction;
    }
    if (long) {
        if (lower_register == program_counter or lower_register == left_register or
            lower_register == upper_register) return error.UnsupportedInstruction;
    } else if (accumulate) {
        if (lower_register == program_counter) return error.UnsupportedInstruction;
    } else if (lower_register != 0) return error.UnsupportedInstruction;

    var flags = self.readFlags();
    if (!conditionPassed(condition, flags)) return;
    const left = self.readRegister(left_register);
    const right = self.readRegister(right_register);
    if (long) {
        const signed = instruction & (1 << 22) != 0;
        var result: u64 = if (signed)
            @bitCast(@as(i64, @as(i32, @bitCast(left))) * @as(i64, @as(i32, @bitCast(right))))
        else
            @as(u64, left) * right;
        if (accumulate) {
            const old = (@as(u64, self.readRegister(upper_register)) << 32) |
                self.readRegister(lower_register);
            result +%= old;
        }
        self.writeGeneralRegister(lower_register, @truncate(result));
        self.writeGeneralRegister(upper_register, @truncate(result >> 32));
        flags.negative = result >> 63 != 0;
        flags.zero = result == 0;
    } else {
        var result = left *% right;
        if (accumulate) result +%= self.readRegister(lower_register);
        self.writeGeneralRegister(upper_register, result);
        flags.negative = result >> 31 != 0;
        flags.zero = result == 0;
    }
    // Preserve unspecified flags until hardware-specific multiply flags are modeled.
    if (instruction & (1 << 20) != 0) self.writeFlags(flags);
}

fn executeArmBranch(self: *Cpu, bus: anytype, instruction: u32, condition: u4) void {
    const address = self.instruction_address;
    // The sequential fetch happens even if a taken branch discards it.
    _ = self.advanceArmPipeline(bus);
    if (!conditionPassed(condition, self.readFlags())) return;

    if (instruction & (1 << 24) != 0) {
        self.writeGeneralRegister(link_register, address +% 4);
    }
    const words: i24 = @bitCast(@as(u24, @truncate(instruction)));
    const offset: u32 = @bitCast(@as(i32, words) * 4);
    self.instruction_address = address +% 8 +% offset;
    self.refillArmPipeline(bus);
}

fn executeArmSwi(self: *Cpu, bus: anytype, condition: u4) void {
    // Advance first so the current address becomes the return address.
    _ = self.advanceArmPipeline(bus);
    if (!conditionPassed(condition, self.readFlags())) return;

    const supervisor_spsr = 1;
    const irq_disable_bit: u32 = 1 << 7;
    const mode_mask: u32 = 0x1F;
    self.spsr[supervisor_spsr] = self.cpsr;
    self.cpsr = (self.cpsr & ~(mode_mask | thumb_bit)) |
        irq_disable_bit | @as(u32, @backingInt(Mode.supervisor));
    // Write LR after switching modes so the return address goes into the Supervisor bank.
    self.writeGeneralRegister(link_register, self.instruction_address);
    self.instruction_address = 0x08;
    self.refillArmPipeline(bus);
}

fn executeArmMrs(self: *Cpu, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    const destination: u4 = @truncate(instruction >> 12);
    if (condition == 0xF) return error.UnsupportedInstruction;
    if (destination == program_counter) return error.UnsupportedInstruction;
    if (!conditionPassed(condition, self.readFlags())) return;

    const value = if (instruction & (1 << 22) != 0)
        self.savedStatus() orelse return error.UnsupportedInstruction
    else
        self.cpsr;
    self.writeGeneralRegister(destination, value);
}

fn executeArmMsr(self: *Cpu, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;
    if (!conditionPassed(condition, self.readFlags())) return;

    const value = if (instruction & (1 << 25) != 0) blk: {
        const immediate: u8 = @truncate(instruction);
        const rotation: u4 = @truncate(instruction >> 8);
        break :blk std.math.rotr(u32, immediate, @as(u5, rotation) * 2);
    } else blk: {
        const source: u4 = @truncate(instruction);
        if (source == program_counter) return error.UnsupportedInstruction;
        break :blk self.readRegister(source);
    };
    const fields: u4 = @truncate(instruction >> 16);
    var mask: u32 = 0;
    for (0..4) |field| {
        if (fields & (@as(u4, 1) << @as(u2, @intCast(field))) != 0) {
            mask |= @as(u32, 0xFF) << @as(u5, @intCast(field * 8));
        }
    }
    if (instruction & (1 << 22) != 0) {
        const index = self.savedStatusIndex() orelse return error.UnsupportedInstruction;
        self.spsr[index] = (self.spsr[index] & ~mask) | (value & mask);
        return;
    }
    // User mode can write only the selected flags byte, not the control bytes.
    if (self.mode() == .user) mask &= 0xFF00_0000;
    // MSR is not an instruction-set transition. Leave those encodings unsupported.
    const updated = (self.cpsr & ~mask) | (value & mask);
    if (updated & thumb_bit != 0) return error.UnsupportedInstruction;
    switch (@as(u5, @truncate(updated))) {
        0x10, 0x11, 0x12, 0x13, 0x17, 0x1B, 0x1F => {},
        else => return error.UnsupportedInstruction,
    }
    self.cpsr = updated;
}

fn savedStatus(self: *Cpu) ?u32 {
    const index = self.savedStatusIndex() orelse return null;
    return self.spsr[index];
}

fn savedStatusIndex(self: *Cpu) ?usize {
    return switch (self.mode()) {
        .user, .system => null,
        .fiq => 0,
        .supervisor => 1,
        .abort => 2,
        .irq => 3,
        .undefined_instruction => 4,
    };
}

const ArmDataProcessing = struct {
    operation: enum { mov, mvn, and_, eor, orr, bic, tst, teq, add, adc, sub, sbc, rsb, rsc, cmp, cmn },
    condition: u4,
    set_flags: bool,
    source: u4,
    destination: u4,
    operand: Operand,

    const Operand = union(enum) {
        immediate: struct { value: u32, rotated: bool },
        shifted_register: RegisterShift,
    };
    const RegisterShift = struct { register: u4, kind: u2, amount: union(enum) { immediate: u5, register: u4 } };
};

fn decodeArmDataProcessing(instruction: u32) error{UnsupportedInstruction}!ArmDataProcessing {
    const condition: u4 = @truncate(instruction >> 28);
    const destination: u4 = @truncate(instruction >> 12);

    if (condition == 0xF) return error.UnsupportedInstruction;
    const immediate_operand = instruction & (1 << 25) != 0;
    const operand_register: u4 = @truncate(instruction);
    if (!immediate_operand) {
        if (instruction & (1 << 4) != 0) {
            // Bit 7 must be clear; otherwise this can be a different encoding family.
            if (instruction & (1 << 7) != 0) return error.UnsupportedInstruction;
            const shift_register: u4 = @truncate(instruction >> 8);
            if (shift_register == program_counter) return error.UnsupportedInstruction;
        }
    }
    // Bits 27–26 select the encoding family; bits 24–21 name the ALU operation.
    const family: u2 = @truncate(instruction >> 26);
    if (family != 0) return error.UnsupportedInstruction;
    const opcode: u4 = @truncate(instruction >> 21);
    const set_flags = instruction & (1 << 20) != 0;
    const source: u4 = @truncate(instruction >> 16);
    var decoded: ArmDataProcessing = .{
        .operation = switch (opcode) {
            0b0000 => .and_,
            0b0001 => .eor,
            0b1000 => .tst,
            0b1001 => .teq,
            0b1100 => .orr,
            0b1101 => .mov,
            0b1110 => .bic,
            0b1111 => .mvn,
            0b0100 => .add,
            0b0010 => .sub,
            0b1010 => .cmp,
            0b0011 => .rsb,
            0b0101 => .adc,
            0b0110 => .sbc,
            0b0111 => .rsc,
            0b1011 => .cmn,
        },
        .condition = condition,
        .set_flags = set_flags,
        .source = source,
        .destination = destination,
        .operand = undefined,
    };
    if (destination == program_counter and set_flags) return error.UnsupportedInstruction;
    switch (decoded.operation) {
        .mov, .mvn => {
            if (source != 0) return error.UnsupportedInstruction;
        },
        .and_, .eor, .orr, .bic, .tst, .teq => {
            // With S clear, these test opcodes overlap other encoding families.
            if (decoded.operation == .tst or decoded.operation == .teq) {
                if (!set_flags) return error.UnsupportedInstruction;
            }
        },
        .add, .adc, .sub, .sbc, .rsb, .rsc, .cmp, .cmn => {
            if (decoded.operation == .cmp or decoded.operation == .cmn) {
                if (!set_flags) return error.UnsupportedInstruction;
            }
        },
    }
    if (immediate_operand) {
        const immediate: u8 = @truncate(instruction);
        const rotation: u4 = @truncate(instruction >> 8);
        decoded.operand = .{ .immediate = .{
            .value = std.math.rotr(u32, immediate, @as(u5, rotation) * 2),
            .rotated = rotation != 0,
        } };
    } else {
        decoded.operand = .{ .shifted_register = .{
            .register = operand_register,
            .kind = @truncate(instruction >> 5),
            .amount = if (instruction & (1 << 4) != 0)
                .{ .register = @truncate(instruction >> 8) }
            else
                .{ .immediate = @truncate(instruction >> 7) },
        } };
    }
    return decoded;
}

// Return a redirect instead of writing PC so step can preserve fetch ordering.
fn executeArmDataProcessing(self: *Cpu, decoded: ArmDataProcessing) ?u32 {
    if (!conditionPassed(decoded.condition, self.readFlags())) return null;
    const old_flags = self.readFlags();
    const operand: ShifterResult = switch (decoded.operand) {
        .immediate => |immediate| .{
            .value = immediate.value,
            .carry = if (immediate.rotated) immediate.value >> 31 != 0 else old_flags.carry,
        },
        .shifted_register => |shift| self.shiftedRegisterOperand(shift),
    };
    const value = operand.value;
    const register_shift = switch (decoded.operand) {
        .immediate => false,
        .shifted_register => |shift| switch (shift.amount) {
            .immediate => false,
            .register => true,
        },
    };
    const source = decoded.source;
    const destination = decoded.destination;
    switch (decoded.operation) {
        .mov, .mvn, .and_, .eor, .orr, .bic, .tst, .teq => {
            const result = switch (decoded.operation) {
                .mov => value,
                .mvn => ~value,
                .and_, .tst => self.readArmAluRegister(source, register_shift) & value,
                .eor, .teq => self.readArmAluRegister(source, register_shift) ^ value,
                .orr => self.readArmAluRegister(source, register_shift) | value,
                .bic => self.readArmAluRegister(source, register_shift) & ~value,
                else => unreachable,
            };
            switch (decoded.operation) {
                .tst, .teq => {},
                else => {
                    if (destination == program_counter) return result;
                    self.writeGeneralRegister(destination, result);
                },
            }
            if (decoded.set_flags) self.writeFlags(.{
                .negative = result >> 31 != 0,
                .zero = result == 0,
                .carry = operand.carry,
                .overflow = old_flags.overflow,
            });
        },
        .add, .adc, .sub, .sbc, .rsb, .rsc, .cmp, .cmn => {
            const left = self.readArmAluRegister(source, register_shift);
            const result = switch (decoded.operation) {
                .add, .cmn => addWithCarry(left, value, false),
                .adc => addWithCarry(left, value, old_flags.carry),
                .sub, .cmp => addWithCarry(left, ~value, true),
                .sbc => addWithCarry(left, ~value, old_flags.carry),
                .rsb => addWithCarry(value, ~left, true),
                .rsc => addWithCarry(value, ~left, old_flags.carry),
                else => unreachable,
            };
            switch (decoded.operation) {
                .cmp, .cmn => {},
                else => {
                    if (destination == program_counter) return result.value;
                    self.writeGeneralRegister(destination, result.value);
                },
            }
            if (decoded.set_flags) self.writeFlags(result.flags);
        },
    }
    return null;
}

fn addWithCarry(left: u32, right: u32, carry_in: bool) struct { value: u32, flags: Flags } {
    const wide = @as(u64, left) + right + @intFromBool(carry_in);
    const result: u32 = @truncate(wide);
    return .{
        .value = result,
        .flags = .{
            .negative = result >> 31 != 0,
            .zero = result == 0,
            .carry = wide >> 32 != 0,
            .overflow = ((left ^ result) & (right ^ result)) >> 31 != 0,
        },
    };
}

const ShifterResult = struct { value: u32, carry: bool };

fn shiftedRegisterOperand(self: *Cpu, shift: ArmDataProcessing.RegisterShift) ShifterResult {
    const register_shift = switch (shift.amount) {
        .immediate => false,
        .register => true,
    };
    const value = self.readArmAluRegister(shift.register, register_shift);
    const kind = shift.kind;
    const amount = switch (shift.amount) {
        .immediate => |count| count,
        .register => |register| blk: {
            const count: u8 = @truncate(self.readRegister(register));
            // Register shifts by zero preserve carry; they never encode RRX or #32.
            if (count == 0) return .{ .value = value, .carry = self.readFlags().carry };
            if (count < 32) break :blk @as(u5, @intCast(count));
            const sign = value >> 31 != 0;
            return switch (kind) {
                0 => .{ .value = 0, .carry = count == 32 and value & 1 != 0 },
                1 => .{ .value = 0, .carry = count == 32 and sign },
                2 => .{ .value = if (sign) 0xFFFF_FFFF else 0, .carry = sign },
                3 => rotate: {
                    const result = std.math.rotr(u32, value, @as(u5, @truncate(count)));
                    break :rotate .{ .value = result, .carry = result >> 31 != 0 };
                },
            };
        },
    };
    // Zero encodes 32 for LSR/ASR and rotate-through-carry for ROR.
    if (amount == 0) return switch (kind) {
        0 => .{ .value = value, .carry = self.readFlags().carry },
        1 => .{ .value = 0, .carry = value >> 31 != 0 },
        2 => .{ .value = @bitCast(@as(i32, @bitCast(value)) >> 31), .carry = value >> 31 != 0 },
        3 => .{
            .value = (value >> 1) | (@as(u32, @intFromBool(self.readFlags().carry)) << 31),
            .carry = value & 1 != 0,
        },
    };
    const result: u32 = switch (kind) {
        0 => value << amount,
        1 => value >> amount,
        2 => @bitCast(@as(i32, @bitCast(value)) >> amount),
        3 => std.math.rotr(u32, value, amount),
    };
    const carry_bit = if (kind == 0) 0 -% amount else amount - 1;
    return .{ .value = result, .carry = (value >> carry_bit) & 1 != 0 };
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

// Return the physical bank currently visible at the top of the register file.
fn activeBank(self: *Cpu) []u32 {
    return switch (self.mode()) {
        .user, .system => self.registers[15..15],
        .fiq => &self.banked.fiq,
        .supervisor => &self.banked.supervisor,
        .abort => &self.banked.abort,
        .irq => &self.banked.irq,
        .undefined_instruction => &self.banked.undefined_instruction,
    };
}

fn readArmAluRegister(self: *Cpu, index: u4, register_shift: bool) u32 {
    // Register-controlled shifts read ALU operands one pipeline cycle later.
    if (index == program_counter and register_shift) return self.instruction_address +% 12;
    return self.readRegister(index);
}

pub fn readRegister(self: *Cpu, index: u4) u32 {
    if (index == program_counter) {
        const offset: u32 = if (self.cpsr & thumb_bit != 0) 4 else 8;
        return self.instruction_address +% offset;
    }
    if (index >= 8) {
        const bank = self.activeBank();
        const first = 15 - bank.len;
        if (index >= first) return bank[index - first];
    }
    return self.registers[index];
}

fn writeGeneralRegister(self: *Cpu, index: u4, value: u32) void {
    // PC writes must go through the control-flow path.
    std.debug.assert(index < program_counter);
    if (index >= 8) {
        const bank = self.activeBank();
        const first = 15 - bank.len;
        if (index >= first) {
            bank[index - first] = value;
            return;
        }
    }
    self.registers[index] = value;
}

fn mode(self: *Cpu) Mode {
    const mode_bits: u5 = @truncate(self.cpsr);
    return @fromBackingInt(mode_bits);
}

test "ARM ALU PC operand depends on the shift encoding" {
    var cpu: Cpu = .{ .instruction_address = 0x0800_0000 };
    // MOV r0, pc; MOV r0, pc, LSL r1 (r1 contains zero).
    _ = cpu.executeArmDataProcessing(try decodeArmDataProcessing(0xE1A0_000F));
    try std.testing.expectEqual(@as(u32, 0x0800_0008), cpu.registers[0]);
    _ = cpu.executeArmDataProcessing(try decodeArmDataProcessing(0xE1A0_011F));
    try std.testing.expectEqual(@as(u32, 0x0800_000C), cpu.registers[0]);
}

test "SP banks follow mode and User and System share storage" {
    var cpu: Cpu = .{};
    cpu.writeGeneralRegister(stack_pointer, 1);
    cpu.cpsr = 0xD2; // IRQ.
    cpu.writeGeneralRegister(stack_pointer, 2);
    cpu.cpsr = 0xD0; // User.
    cpu.writeGeneralRegister(stack_pointer, 3);
    cpu.cpsr = 0xDF; // System.
    try std.testing.expectEqual(@as(u32, 3), cpu.readRegister(stack_pointer));
    cpu.cpsr = 0xD2;
    try std.testing.expectEqual(@as(u32, 2), cpu.readRegister(stack_pointer));
    cpu.cpsr = 0xD3;
    try std.testing.expectEqual(@as(u32, 1), cpu.readRegister(stack_pointer));
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

        pub fn fetch16(_: *@This(), _: u32) u16 {
            unreachable;
        }

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
