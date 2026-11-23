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
pub const FetchAccess = @import("timing.zig").Access;

registers: [15]u32 = @splat(0),
banked: BankedRegisters = .{},
instruction_address: u32 = 0,
// Current instruction first, then the next one. Null until the initial refill.
pipeline: ?[2]u32 = null,
cpsr: u32 = 0xD3, // Supervisor mode, ARM state, IRQ and FIQ masked.
// FIQ, Supervisor, Abort, IRQ, Undefined, in bank order.
spsr: [5]u32 = @splat(0),
// Counts only the internal cycles explicitly modeled by instruction handlers.
internal_cycles: u64 = 0,

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
const irq_disable_bit: u32 = 1 << 7;
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
    const current = bus.fetch32(self.instruction_address, .nonsequential);
    const next = bus.fetch32(self.instruction_address +% 4, .sequential);
    self.pipeline = .{ current, next };
}

pub fn step(self: *Cpu, bus: anytype) error{ PipelineNotReady, UnsupportedInstruction }!void {
    const queued = self.pipeline orelse return error.PipelineNotReady;
    if (self.cpsr & thumb_bit != 0) {
        try self.stepThumb(bus, @truncate(queued[0]));
        return;
    }
    const instruction = queued[0];
    if (try decodeArmDataProcessing(instruction)) |decoded| {
        try self.stepArmDataProcessing(bus, decoded);
        return;
    }
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
    if (instruction & 0x0FB0_0FF0 == 0x0100_0090) {
        try self.executeArmSwap(bus, instruction);
        return;
    }
    // Multiply encodings overlap the data-processing space.
    if (instruction & 0x0FC0_00F0 == 0x0000_0090 or instruction & 0x0F80_00F0 == 0x0080_0090) {
        try self.executeArmMultiply(instruction);
        _ = self.advanceArmPipeline(bus);
        return;
    }
    if (instruction & 0x0E00_0000 == 0x0800_0000) {
        try self.executeArmBlockTransfer(bus, instruction);
        return;
    }
    const single_transfer = instruction & 0x0C00_0000 == 0x0400_0000;
    const extra_transfer = instruction & 0x0E00_0090 == 0x0000_0090 and
        instruction & 0x60 != 0;
    if (single_transfer or extra_transfer) {
        try self.executeArmTransfer(bus, instruction, extra_transfer);
        return;
    }
    return error.UnsupportedInstruction;
}

fn stepArmDataProcessing(self: *Cpu, bus: anytype, decoded: ArmDataProcessing) error{UnsupportedInstruction}!void {
    const writes_result = switch (decoded.operation) {
        .tst, .teq, .cmp, .cmn => false,
        else => true,
    };
    const return_status: ?u32 = blk: {
        if (decoded.destination != program_counter or !decoded.set_flags) break :blk null;
        if (!conditionPassed(decoded.condition, self.readFlags())) break :blk null;
        if (self.savedStatus()) |status| break :blk status;
        if (writes_result) return error.UnsupportedInstruction;
        break :blk self.cpsr;
    };
    const redirect = self.executeArmDataProcessing(decoded);
    _ = self.advanceArmPipeline(bus);
    if (return_status) |status| self.cpsr = status;
    if (redirect) |target| {
        if (self.cpsr & thumb_bit != 0) {
            self.instruction_address = target & ~@as(u32, 1);
            self.refillThumbPipeline(bus);
        } else {
            self.instruction_address = target & ~@as(u32, 3);
            self.refillArmPipeline(bus);
        }
    } else if (self.cpsr & thumb_bit != 0) {
        // Test and compare encodings with Rd = PC restore status without branching.
        self.refillThumbPipeline(bus);
    }
}

fn executeArmSwap(self: *Cpu, bus: anytype, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;
    if (!conditionPassed(condition, self.readFlags())) {
        _ = self.advanceArmPipeline(bus);
        return;
    }

    const base: u4 = @truncate(instruction >> 16);
    const destination: u4 = @truncate(instruction >> 12);
    const source: u4 = @truncate(instruction);
    if (base == program_counter or destination == program_counter or source == program_counter) {
        return error.UnsupportedInstruction;
    }
    const address = self.readRegister(base);
    const outgoing = self.readRegister(source);
    _ = self.advanceArmPipeline(bus);

    // Read and write as one instruction, before replacing any aliased source register.
    const incoming: u32 = if (instruction & (1 << 22) != 0) blk: {
        const previous = bus.readData(u8, address);
        bus.writeData(u8, address, @truncate(outgoing));
        break :blk previous;
    } else blk: {
        const previous = std.math.rotr(u32, bus.readData(u32, address), (address & 3) * 8);
        bus.writeData(u32, address, outgoing);
        break :blk previous;
    };
    self.internal_cycles += 1;
    self.writeGeneralRegister(destination, incoming);
}

fn executeArmBlockTransfer(
    self: *Cpu,
    bus: anytype,
    instruction: u32,
) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;
    if (!conditionPassed(condition, self.readFlags())) {
        _ = self.advanceArmPipeline(bus);
        return;
    }

    const before = instruction & (1 << 24) != 0;
    const increment = instruction & (1 << 23) != 0;
    const special = instruction & (1 << 22) != 0;
    const writeback = instruction & (1 << 21) != 0;
    const load = instruction & (1 << 20) != 0;
    const base_register: u4 = @truncate(instruction >> 16);
    if (base_register == program_counter) return error.UnsupportedInstruction;
    var registers: u16 = @truncate(instruction);
    // An empty list transfers PC but moves the base by sixteen words.
    const count: u32 = if (registers == 0) 16 else @popCount(registers);
    if (registers == 0) registers = 1 << program_counter;

    const loads_pc = load and registers & (1 << program_counter) != 0;
    const return_status: ?u32 = if (special and loads_pc) blk: {
        const status = self.savedStatus() orelse return error.UnsupportedInstruction;
        switch (@as(u5, @truncate(status))) {
            0x10, 0x11, 0x12, 0x13, 0x17, 0x1B, 0x1F => {},
            else => return error.UnsupportedInstruction,
        }
        break :blk status;
    } else null;
    const user_bank = special and !loads_pc;
    if (user_bank and (writeback or self.mode() == .user or self.mode() == .system)) {
        return error.UnsupportedInstruction;
    }

    const base = self.readRegister(base_register);
    const updated_base = if (increment) base +% (count * 4) else base -% (count * 4);
    // Even decrementing modes transfer the lowest register at the lowest address.
    var address = if (increment) base else updated_base;
    if (before == increment) address +%= 4;
    const base_in_list = registers & (@as(u16, 1) << base_register) != 0;
    const first_register: u4 = @intCast(@ctz(registers));
    _ = self.advanceArmPipeline(bus);

    var target: ?u32 = null;
    while (registers != 0) {
        const register: u4 = @intCast(@ctz(registers));
        registers &= registers - 1;
        if (load) {
            const value = bus.readData(u32, address);
            if (register == program_counter) {
                target = value;
            } else if (user_bank) {
                self.registers[register] = value;
            } else {
                self.writeGeneralRegister(register, value);
            }
        } else {
            // ARM7 stores the updated base if an earlier register transferred first.
            const value = if (writeback and register == base_register and register != first_register)
                updated_base
            else if (user_bank and register != program_counter)
                self.registers[register]
            else
                self.readRegister(register);
            bus.writeData(u32, address, value);
        }
        address +%= 4;
    }
    if (load) self.internal_cycles += 1;
    if (writeback and (!load or !base_in_list)) {
        self.writeGeneralRegister(base_register, updated_base);
    }
    if (target) |value| {
        // Writeback belongs to the old bank; restore CPSR before fetching the return target.
        if (return_status) |status| self.cpsr = status;
        if (self.cpsr & thumb_bit != 0) {
            self.instruction_address = value & ~@as(u32, 1);
            self.refillThumbPipeline(bus);
        } else {
            self.instruction_address = value & ~@as(u32, 3);
            self.refillArmPipeline(bus);
        }
    }
}

fn executeArmTransfer(
    self: *Cpu,
    bus: anytype,
    instruction: u32,
    extra: bool,
) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;
    if (!conditionPassed(condition, self.readFlags())) {
        _ = self.advanceArmPipeline(bus);
        return;
    }

    const pre_index = instruction & (1 << 24) != 0;
    const add = instruction & (1 << 23) != 0;
    const writeback_bit = instruction & (1 << 21) != 0;
    const load = instruction & (1 << 20) != 0;
    const base_register: u4 = @truncate(instruction >> 16);
    const data_register: u4 = @truncate(instruction >> 12);
    const offset_register: u4 = @truncate(instruction);
    // Post-indexed T forms use the same data bus path until it models access privilege.
    const writeback = !pre_index or writeback_bit;
    if (writeback and base_register == program_counter) return error.UnsupportedInstruction;

    const Operation = enum { word, byte, halfword, signed_byte, signed_halfword };
    const operation: Operation = if (extra) switch (@as(u2, @truncate(instruction >> 5))) {
        1 => .halfword,
        2 => .signed_byte,
        3 => .signed_halfword,
        else => unreachable,
    } else if (instruction & (1 << 22) != 0) .byte else .word;

    const offset: u32 = if (extra) blk: {
        // Halfword and signed transfers have no post-indexed T encoding on ARMv4T.
        if (!pre_index and writeback_bit) return error.UnsupportedInstruction;
        if (!load and operation != .halfword) return error.UnsupportedInstruction;
        if (instruction & (1 << 22) != 0) {
            break :blk ((instruction >> 4) & 0xF0) | (instruction & 0xF);
        }
        if (instruction & 0xF00 != 0) return error.UnsupportedInstruction;
        break :blk self.readRegister(offset_register);
    } else if (instruction & (1 << 25) != 0) blk: {
        if (instruction & (1 << 4) != 0) return error.UnsupportedInstruction;
        break :blk self.shiftedRegisterOperand(.{
            .register = offset_register,
            .kind = @truncate(instruction >> 5),
            .amount = .{ .immediate = @truncate(instruction >> 7) },
        }).value;
    } else instruction & 0xFFF;

    const base = self.readRegister(base_register);
    const updated_base = if (add) base +% offset else base -% offset;
    const address = if (pre_index) updated_base else base;
    _ = self.advanceArmPipeline(bus);

    if (!load) {
        // A store of R15 sees the PC after the sequential fetch (instruction + 12).
        const value = self.readRegister(data_register);
        switch (operation) {
            .word => bus.writeData(u32, address, value),
            .byte => bus.writeData(u8, address, @truncate(value)),
            .halfword => bus.writeData(u16, address, @truncate(value)),
            .signed_byte, .signed_halfword => unreachable,
        }
        if (writeback) self.writeGeneralRegister(base_register, updated_base);
        return;
    }

    const value: u32 = switch (operation) {
        .word => std.math.rotr(u32, bus.readData(u32, address), (address & 3) * 8),
        .byte => bus.readData(u8, address),
        .halfword => std.math.rotr(u32, bus.readData(u16, address), (address & 1) * 8),
        .signed_byte => signExtendByte(bus.readData(u8, address)),
        .signed_halfword => readSignedHalfword(bus, address),
    };
    // The load completes with an internal cycle before the result is available.
    self.internal_cycles += 1;
    if (writeback and base_register != data_register) {
        self.writeGeneralRegister(base_register, updated_base);
    }
    if (data_register == program_counter) {
        self.instruction_address = value & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    } else {
        self.writeGeneralRegister(data_register, value);
    }
}

fn stepThumb(self: *Cpu, bus: anytype, instruction: u16) error{UnsupportedInstruction}!void {
    const pc = self.instruction_address +% 4;
    if (self.decodeThumbTransfer(instruction)) |transfer| {
        self.advanceThumbPipeline(bus, pc);
        self.executeThumbTransfer(bus, transfer);
        return;
    }
    const stack_transfer = instruction & 0xF600 == 0xB400;
    if (stack_transfer or instruction >> 12 == 0xC) {
        self.advanceThumbPipeline(bus, pc);
        self.executeThumbBlockTransfer(bus, instruction, stack_transfer);
        return;
    }
    const immediate: u11 = @truncate(instruction);
    const signed_immediate: i32 = @as(i11, @bitCast(immediate));
    var target: ?u32 = null;
    const software_interrupt = instruction >> 8 == 0xDF;
    const exchange = instruction & 0xFF87 == 0x4700;
    if (software_interrupt) {
        // Exception entry runs after the sequential Thumb fetch.
    } else if (exchange) {
        const source: u4 = @truncate(instruction >> 3);
        target = self.readRegister(source);
    } else if (instruction >> 10 == 0b010001) {
        target = try self.executeThumbHighAlu(instruction);
    } else if (instruction >> 12 == 0xD) {
        const condition: u4 = @truncate(instruction >> 8);
        if (condition >= 0xE) return error.UnsupportedInstruction;
        if (conditionPassed(condition, self.readFlags())) {
            const displacement: i8 = @bitCast(@as(u8, @truncate(instruction)));
            target = pc +% @as(u32, @bitCast(@as(i32, displacement) * 2));
        }
    } else switch (instruction >> 11) {
        0b11100 => target = pc +% @as(u32, @bitCast(signed_immediate * 2)),
        0b11110 => {
            // BL's prefix stores the signed high displacement in the active LR bank.
            const base = pc +% @as(u32, @bitCast(signed_immediate * 4096));
            self.writeGeneralRegister(link_register, base);
        },
        0b11111 => {
            target = (self.readRegister(link_register) +% (@as(u32, immediate) * 2)) &
                ~@as(u32, 1);
            // Bit zero marks the return address as Thumb for BX.
            self.writeGeneralRegister(link_register, (self.instruction_address +% 2) | 1);
        },
        else => try self.executeThumbLowAlu(instruction),
    }

    // A taken branch still performs the sequential fetch before refilling.
    self.advanceThumbPipeline(bus, pc);
    if (software_interrupt) {
        self.enterSoftwareInterrupt(bus);
    } else if (target) |address| {
        if (exchange and address & 1 == 0) {
            self.cpsr &= ~thumb_bit;
            self.instruction_address = address & ~@as(u32, 3);
            self.refillArmPipeline(bus);
        } else {
            self.instruction_address = address & ~@as(u32, 1);
            self.refillThumbPipeline(bus);
        }
    }
}

fn advanceThumbPipeline(self: *Cpu, bus: anytype, fetch_address: u32) void {
    const queued = self.pipeline.?;
    self.pipeline = .{ queued[1], bus.fetch16(fetch_address, .sequential) };
    self.instruction_address +%= 2;
}

const ThumbTransfer = struct {
    operation: enum(u3) { str, strh, strb, ldrsb, ldr, ldrh, ldrb, ldrsh },
    address: u32,
    register: u3,
};

fn decodeThumbTransfer(self: *Cpu, instruction: u16) ?ThumbTransfer {
    const low_register: u3 = @truncate(instruction);
    const high_register: u3 = @truncate(instruction >> 8);
    const base_register: u3 = @truncate(instruction >> 3);
    const offset: u32 = @as(u5, @truncate(instruction >> 6));
    const load = instruction & (1 << 11) != 0;
    const offset_word = @as(u32, @as(u8, @truncate(instruction))) * 4;
    return switch (instruction >> 12) {
        4 => if (load) .{
            .operation = .ldr,
            .address = (self.readRegister(program_counter) & ~@as(u32, 3)) +% offset_word,
            .register = high_register,
        } else null,
        5 => .{
            .operation = @enumFromInt(@as(u3, @truncate(instruction >> 9))),
            .address = self.readRegister(base_register) +% self.readRegister(@as(u3, @truncate(instruction >> 6))),
            .register = low_register,
        },
        6, 7, 8 => blk: {
            const width: u32 = switch (instruction >> 12) {
                6 => 4,
                7 => 1,
                8 => 2,
                else => unreachable,
            };
            break :blk .{
                .operation = switch (width) {
                    4 => if (load) .ldr else .str,
                    2 => if (load) .ldrh else .strh,
                    1 => if (load) .ldrb else .strb,
                    else => unreachable,
                },
                .address = self.readRegister(base_register) +% (offset * width),
                .register = low_register,
            };
        },
        9 => .{
            .operation = if (load) .ldr else .str,
            .address = self.readRegister(stack_pointer) +% offset_word,
            .register = high_register,
        },
        else => null,
    };
}

fn executeThumbTransfer(self: *Cpu, bus: anytype, transfer: ThumbTransfer) void {
    const address = transfer.address;
    const register = transfer.register;
    const result: u32 = switch (transfer.operation) {
        // The bus receives the effective address but accesses naturally aligned data.
        .str => return bus.writeData(u32, address, self.readRegister(register)),
        .strh => return bus.writeData(u16, address, @truncate(self.readRegister(register))),
        .strb => return bus.writeData(u8, address, @truncate(self.readRegister(register))),
        .ldr => std.math.rotr(u32, bus.readData(u32, address), (address & 3) * 8),
        .ldrh => std.math.rotr(u32, bus.readData(u16, address), (address & 1) * 8),
        .ldrb => bus.readData(u8, address),
        .ldrsb => signExtendByte(bus.readData(u8, address)),
        .ldrsh => readSignedHalfword(bus, address),
    };
    self.internal_cycles += 1;
    self.writeGeneralRegister(register, result);
}

fn executeThumbBlockTransfer(self: *Cpu, bus: anytype, instruction: u16, stack: bool) void {
    const load = instruction & (1 << 11) != 0;
    const base_register: u4 = if (stack) stack_pointer else @as(u3, @truncate(instruction >> 8));
    const base = self.readRegister(base_register);
    var registers: u16 = instruction & 0xFF;
    if (stack and instruction & (1 << 8) != 0) {
        registers |= @as(u16, 1) << if (load) program_counter else link_register;
    }
    // ARM7TDMI transfers PC for an empty list but adjusts the base by 16 words.
    const count: u32 = if (registers == 0) 16 else @popCount(registers);
    if (registers == 0) registers = 1 << program_counter;
    const push = stack and !load;
    const writeback = if (push) base -% (count * 4) else base +% (count * 4);
    var address = if (push) writeback else base;
    const first_register: u4 = @intCast(@ctz(registers));
    var target: ?u32 = null;

    // The lowest register always uses the lowest address, including on PUSH.
    while (registers != 0) {
        const register: u4 = @intCast(@ctz(registers));
        registers &= registers - 1;
        if (load) {
            const value = bus.readData(u32, address);
            if (register == program_counter) {
                target = value;
            } else {
                self.writeGeneralRegister(register, value);
            }
        } else {
            // STMIA stores the updated base unless it is the first register transferred.
            const value = if (register == base_register and register != first_register)
                writeback
            else
                self.readRegister(register);
            bus.writeData(u32, address, value);
        }
        address +%= 4;
    }

    if (load) self.internal_cycles += 1;
    // LDMIA lets a loaded base register win over writeback.
    const base_in_list = !stack and instruction & (@as(u16, 1) << base_register) != 0;
    if (!load or !base_in_list) self.writeGeneralRegister(base_register, writeback);
    if (target) |value| {
        self.instruction_address = value & ~@as(u32, 1);
        self.refillThumbPipeline(bus);
    }
}

fn readSignedHalfword(bus: anytype, address: u32) u32 {
    const value = bus.readData(u16, address);
    // An odd address selects and sign-extends the upper byte of the halfword.
    if (address & 1 != 0) return signExtendByte(@truncate(value >> 8));
    return @bitCast(@as(i32, @as(i16, @bitCast(value))));
}

fn signExtendByte(value: u8) u32 {
    return @bitCast(@as(i32, @as(i8, @bitCast(value))));
}

fn executeThumbHighAlu(self: *Cpu, instruction: u16) error{UnsupportedInstruction}!?u32 {
    const operation: u2 = @truncate(instruction >> 8);
    if (operation == 3) return error.UnsupportedInstruction;
    const source: u4 = @truncate(instruction >> 3);
    const destination: u4 = (@as(u4, @truncate(instruction >> 4)) & 8) |
        @as(u3, @truncate(instruction));
    if (source < 8 and destination < 8) return error.UnsupportedInstruction;
    const right = self.readRegister(source);
    if (operation == 1) {
        self.writeFlags(addWithCarry(self.readRegister(destination), ~right, true).flags);
        return null;
    }
    const result = if (operation == 0) self.readRegister(destination) +% right else right;
    // High-register ADD and MOV can redirect PC without exchanging state.
    if (destination == program_counter) return result;
    self.writeGeneralRegister(destination, result);
    return null;
}

fn refillThumbPipeline(self: *Cpu, bus: anytype) void {
    std.debug.assert(self.instruction_address & 1 == 0);
    const current = bus.fetch16(self.instruction_address, .nonsequential);
    const next = bus.fetch16(self.instruction_address +% 2, .sequential);
    self.pipeline = .{ current, next };
}

fn executeThumbLowAlu(self: *Cpu, instruction: u16) error{UnsupportedInstruction}!void {
    if (instruction >> 10 == 0b010000) {
        self.executeThumbRegisterAlu(instruction);
        return;
    }
    if (instruction >> 12 == 0b1010) {
        const destination: u3 = @truncate(instruction >> 8);
        const offset = @as(u32, @as(u8, @truncate(instruction))) * 4;
        // Thumb PC-relative address generation uses a word-aligned PC.
        const base = if (instruction & (1 << 11) != 0)
            self.readRegister(stack_pointer)
        else
            self.readRegister(program_counter) & ~@as(u32, 3);
        self.writeGeneralRegister(destination, base +% offset);
        return;
    }
    if (instruction >> 8 == 0xB0) {
        const offset = @as(u32, @as(u7, @truncate(instruction))) * 4;
        const base = self.readRegister(stack_pointer);
        const result = if (instruction & (1 << 7) != 0) base -% offset else base +% offset;
        self.writeGeneralRegister(stack_pointer, result);
        return;
    }
    switch (instruction >> 13) {
        0b000 => {
            const destination: u3 = @truncate(instruction);
            const source: u3 = @truncate(instruction >> 3);
            const kind: u2 = @truncate(instruction >> 11);
            if (kind == 3) {
                const operand: u3 = @truncate(instruction >> 6);
                const right = if (instruction & (1 << 10) != 0)
                    @as(u32, operand)
                else
                    self.readRegister(operand);
                const subtract = instruction & (1 << 9) != 0;
                const result = addWithCarry(self.readRegister(source), if (subtract) ~right else right, subtract);
                self.writeGeneralRegister(destination, result.value);
                self.writeFlags(result.flags);
            } else {
                const shifted = self.shiftedRegisterOperand(.{
                    .register = source,
                    .kind = kind,
                    .amount = .{ .immediate = @truncate(instruction >> 6) },
                });
                var flags = self.readFlags();
                flags.negative = shifted.value >> 31 != 0;
                flags.zero = shifted.value == 0;
                flags.carry = shifted.carry;
                self.writeGeneralRegister(destination, shifted.value);
                self.writeFlags(flags);
            }
        },
        0b001 => {
            const operation: u2 = @truncate(instruction >> 11);
            const destination: u3 = @truncate(instruction >> 8);
            const immediate: u32 = @as(u8, @truncate(instruction));
            if (operation == 0) {
                // MOV immediate updates N and Z but keeps C and V.
                var flags = self.readFlags();
                flags.negative = false;
                flags.zero = immediate == 0;
                self.writeGeneralRegister(destination, immediate);
                self.writeFlags(flags);
            } else {
                const subtract = operation != 2;
                const result = addWithCarry(self.readRegister(destination), if (subtract) ~immediate else immediate, subtract);
                // CMP uses the subtraction flags without writing a result.
                if (operation != 1) self.writeGeneralRegister(destination, result.value);
                self.writeFlags(result.flags);
            }
        },
        else => return error.UnsupportedInstruction,
    }
}

fn executeThumbRegisterAlu(self: *Cpu, instruction: u16) void {
    const operation: u4 = @truncate(instruction >> 6);
    const source: u3 = @truncate(instruction >> 3);
    const destination: u3 = @truncate(instruction);
    const left = self.readRegister(destination);
    const right = self.readRegister(source);
    var flags = self.readFlags();
    const result: u32 = switch (operation) {
        0, 8 => left & right, // AND, TST.
        1 => left ^ right, // EOR.
        2, 3, 4, 7 => blk: {
            self.internal_cycles += 1;
            const kind: u2 = if (operation == 7) 3 else @intCast(operation - 2);
            const shifted = self.shiftedRegisterOperand(.{
                .register = destination,
                .kind = kind,
                .amount = .{ .register = source },
            });
            flags.carry = shifted.carry;
            break :blk shifted.value;
        },
        5, 6, 9, 10, 11 => blk: {
            const arithmetic = switch (operation) {
                5 => addWithCarry(left, right, flags.carry), // ADC.
                6 => addWithCarry(left, ~right, flags.carry), // SBC.
                9 => addWithCarry(0, ~right, true), // NEG.
                10 => addWithCarry(left, ~right, true), // CMP.
                11 => addWithCarry(left, right, false), // CMN.
                else => unreachable,
            };
            flags = arithmetic.flags;
            break :blk arithmetic.value;
        },
        12 => left | right, // ORR.
        13 => blk: {
            // Thumb MUL uses the original destination as the timing-sensitive multiplier.
            self.internal_cycles += multiplyCycles(left, true);
            break :blk left *% right;
        },
        14 => left & ~right, // BIC.
        15 => ~right, // MVN.
    };
    switch (operation) {
        8, 10, 11 => {}, // Tests and comparisons only write flags.
        else => self.writeGeneralRegister(destination, result),
    }
    flags.negative = result >> 31 != 0;
    flags.zero = result == 0;
    self.writeFlags(flags);
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
        self.refillThumbPipeline(bus);
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
    // The multiplier reads its operands before writeback, so Rm can also be a destination.
    // The ARM Architecture Reference Manual describes this behavior for ARMv4 implementations.
    if (left_register == program_counter or right_register == program_counter or
        upper_register == program_counter)
    {
        return error.UnsupportedInstruction;
    }
    if (long) {
        if (lower_register == program_counter or lower_register == upper_register)
            return error.UnsupportedInstruction;
    } else if (accumulate) {
        if (lower_register == program_counter) return error.UnsupportedInstruction;
    } else if (lower_register != 0) return error.UnsupportedInstruction;

    var flags = self.readFlags();
    if (!conditionPassed(condition, flags)) return;
    const left = self.readRegister(left_register);
    const right = self.readRegister(right_register);
    const signed = !long or instruction & (1 << 22) != 0;
    const iterations = multiplyCycles(right, signed);
    self.internal_cycles += iterations;
    self.internal_cycles += @intFromBool(accumulate);
    if (long) {
        self.internal_cycles += 1;
        var result: u64 = if (signed)
            @bitCast(@as(i64, @as(i32, @bitCast(left))) * @as(i64, @as(i32, @bitCast(right))))
        else
            @as(u64, left) * right;
        const accumulator = if (accumulate)
            (@as(u64, self.readRegister(upper_register)) << 32) | self.readRegister(lower_register)
        else
            0;
        result +%= accumulator;
        if (instruction & (1 << 20) != 0) {
            flags.carry = longMultiplyCarry(left, right, accumulator, signed, iterations);
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
    if (instruction & (1 << 20) != 0) self.writeFlags(flags);
}

// ARM7TDMI exposes a bit of the carry-save adder through the barrel shifter.
// Hardware model: https://bmchtech.github.io/post/multiply/
fn longMultiplyCarry(rm: u32, rs: u32, accumulator: u64, signed: bool, iterations: u8) bool {
    const multiplicand: u34 = if (signed) @bitCast(@as(i34, @as(i32, @bitCast(rm)))) else rm;
    var digits: u34 = if (signed) @bitCast(@as(i34, @as(i32, @bitCast(rs)))) else rs;
    var sum: u33 = @truncate(accumulator >> 1);
    var carry: u33 = if (rs & 1 != 0) @truncate(~multiplicand >> 1) else 0;
    var high_accumulator = accumulator >> 34;

    // Four overlapping radix-4 Booth digits consume one multiplier byte.
    for (0..@as(usize, iterations) * 4) |_| {
        const addend: u34 = switch (@as(u3, @truncate(digits))) {
            0, 7 => 0,
            1, 2 => multiplicand,
            3 => multiplicand << 1,
            4 => ~(multiplicand << 1),
            5, 6 => ~multiplicand,
        };
        const operand: u33 = @truncate(addend);
        const majority = (sum & carry) | ((sum ^ carry) & operand);
        // Feed the next accumulator and sign-extension bits into the top of
        // the array as the two finished low bits leave each stage.
        const extension = (high_accumulator & 1) + (~carry >> 32) + (~addend >> 33);
        sum = ((sum ^ carry ^ operand) >> 2) | @as(u33, @truncate(extension << 31));
        carry = (majority >> 1) | (@as(u33, @truncate(~high_accumulator >> 1)) << 32);
        high_accumulator >>= 2;
        digits >>= 2;
    }

    // Early termination aligns to the low word, a full multiply to the high word.
    const bit: u5 = @intCast(if (iterations == 4) 30 else 30 - iterations * 8);
    return (carry >> bit) & 1 != 0;
}

fn multiplyCycles(multiplier: u32, allow_ones: bool) u8 {
    // ARM7 exits once the unprocessed high bytes are all zero or sign fill.
    const signed_fill = if (allow_ones and multiplier >> 31 != 0) ~multiplier else multiplier;
    if (signed_fill >> 8 == 0) return 1;
    if (signed_fill >> 16 == 0) return 2;
    if (signed_fill >> 24 == 0) return 3;
    return 4;
}

test "SMLALS includes the original high accumulator in the carry flag" {
    var cpu: Cpu = .{};
    cpu.registers[0] = 0x8000_0000;
    cpu.registers[1] = 0x1234_5678;
    for ([_]u32{ 0x4000_0000, 0 }, [_]bool{ true, false }) |high, expected_carry| {
        cpu.registers[2] = 0;
        cpu.registers[3] = high;
        try cpu.executeArmMultiply(0xE0F3_2190); // SMLALS r2, r3, r0, r1
        try std.testing.expectEqual(expected_carry, cpu.readFlags().carry);
        try std.testing.expectEqual(high -% 0x091A_2B3C, cpu.registers[3]);
        try std.testing.expectEqual(@as(u32, 0), cpu.registers[2]);
    }
}

test "ARM multiply reads aliased source registers before writeback" {
    // MLA uses the output register as an input when the memory ROM computes a pixel offset.
    var cpu: Cpu = .{};
    cpu.registers[0] = 56;
    cpu.registers[1] = 76;
    cpu.registers[4] = 240;
    try cpu.executeArmMultiply(0xE024_0194); // MLA r4, r4, r1, r0
    try std.testing.expectEqual(@as(u32, 18_296), cpu.registers[4]);
    try std.testing.expectEqual(@as(u64, 2), cpu.internal_cycles);

    // Both words of the long accumulator and the aliased multiplicand use their old values.
    cpu.registers[0] = 0xFFFF_FFFF;
    cpu.registers[1] = 7;
    cpu.registers[2] = 2;
    try cpu.executeArmMultiply(0xE0A1_0290); // UMLAL r0, r1, r0, r2
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.registers[0]);
    try std.testing.expectEqual(@as(u32, 9), cpu.registers[1]);

    cpu.registers[0] = 0xFFFF_FFFF;
    cpu.registers[1] = 7;
    try cpu.executeArmMultiply(0xE0A1_0291); // UMLAL r0, r1, r1, r2
    try std.testing.expectEqual(@as(u32, 13), cpu.registers[0]);
    try std.testing.expectEqual(@as(u32, 8), cpu.registers[1]);
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

    self.enterSoftwareInterrupt(bus);
}

fn enterSoftwareInterrupt(self: *Cpu, bus: anytype) void {
    self.enterException(bus, .supervisor, 0x08, self.instruction_address);
}

pub fn irqMasked(self: *const Cpu) bool {
    return self.cpsr & irq_disable_bit != 0;
}

pub fn enterIrq(self: *Cpu, bus: anytype) void {
    std.debug.assert(!self.irqMasked());
    // The interrupted instruction still issues its pipeline fetch before vector refill.
    if (self.cpsr & thumb_bit != 0) {
        _ = bus.fetch16(self.instruction_address +% 4, .sequential);
    } else {
        _ = bus.fetch32(self.instruction_address +% 8, .sequential);
    }
    // IRQ return subtracts four from LR to resume the first unexecuted instruction.
    self.enterException(bus, .irq, 0x18, self.instruction_address +% 4);
}

fn enterException(self: *Cpu, bus: anytype, target_mode: Mode, vector: u32, return_link: u32) void {
    const old_status = self.cpsr;
    const mode_mask: u32 = 0x1F;
    self.cpsr = (old_status & ~(mode_mask | thumb_bit)) |
        irq_disable_bit | @as(u32, @intFromEnum(target_mode));
    // SPSR and LR belong to the exception mode, not the interrupted mode.
    self.spsr[self.savedStatusIndex().?] = old_status;
    self.writeGeneralRegister(link_register, return_link);
    self.instruction_address = vector;
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

// ARM data-processing fields occupy the same bits for both operand forms.
const ArmDataProcessing = packed struct(u32) {
    operand: u12,
    destination: u4,
    source: u4,
    set_flags: bool,
    operation: enum(u4) { and_, eor, sub, rsb, add, adc, sbc, rsc, tst, teq, cmp, cmn, orr, mov, bic, mvn },
    immediate: bool,
    family: u2,
    condition: u4,

    const RegisterShift = struct { register: u4, kind: u2, amount: union(enum) { immediate: u5, register: u4 } };

    fn registerShift(self: ArmDataProcessing) bool {
        return !self.immediate and self.operand & 0x10 != 0;
    }
};

inline fn decodeArmDataProcessing(instruction: u32) error{UnsupportedInstruction}!?ArmDataProcessing {
    const decoded: ArmDataProcessing = @bitCast(instruction);
    if (decoded.family != 0) return null;
    // Test opcodes with S clear share space with status transfers and BX.
    switch (decoded.operation) {
        .tst, .teq, .cmp, .cmn => if (!decoded.set_flags) return null,
        else => {},
    }
    if (decoded.registerShift()) {
        if (decoded.operand & 0x80 != 0) return null; // Multiply or extra transfer.
        if (decoded.operand >> 8 == program_counter) return error.UnsupportedInstruction;
    }
    if (decoded.condition == 0xF) return error.UnsupportedInstruction;
    if ((decoded.operation == .mov or decoded.operation == .mvn) and decoded.source != 0)
        return error.UnsupportedInstruction;
    return decoded;
}

// Return a redirect instead of writing PC so step can preserve fetch ordering.
fn executeArmDataProcessing(self: *Cpu, decoded: ArmDataProcessing) ?u32 {
    if (decoded.condition != 0xE and !conditionPassed(decoded.condition, self.readFlags())) return null;
    const old_flags = self.readFlags();
    const register_shift = decoded.registerShift();
    const operand: ShifterResult = if (decoded.immediate) blk: {
        const rotation: u5 = @as(u5, @intCast(decoded.operand >> 8)) * 2;
        const value = std.math.rotr(u32, @as(u8, @truncate(decoded.operand)), rotation);
        break :blk .{ .value = value, .carry = if (rotation == 0) old_flags.carry else value >> 31 != 0 };
    } else if (decoded.operand >> 4 == 0) .{
        // LSL #0 is the encoding for a plain register operand.
        .value = self.readArmAluRegister(@truncate(decoded.operand), false),
        .carry = old_flags.carry,
    } else self.shiftedRegisterOperand(.{
        .register = @truncate(decoded.operand),
        .kind = @truncate(decoded.operand >> 5),
        .amount = if (register_shift)
            .{ .register = @truncate(decoded.operand >> 8) }
        else
            .{ .immediate = @truncate(decoded.operand >> 7) },
    });
    const value = operand.value;
    if (register_shift) self.internal_cycles += 1;
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
    const fetched = bus.fetch32(self.instruction_address +% 8, .sequential);
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
    return @enumFromInt(mode_bits);
}

test "ARM ALU PC operand depends on the shift encoding" {
    var cpu: Cpu = .{ .instruction_address = 0x0800_0000 };
    // MOV r0, pc; MOV r0, pc, LSL r1 (r1 contains zero).
    _ = cpu.executeArmDataProcessing((try decodeArmDataProcessing(0xE1A0_000F)).?);
    try std.testing.expectEqual(@as(u32, 0x0800_0008), cpu.registers[0]);
    _ = cpu.executeArmDataProcessing((try decodeArmDataProcessing(0xE1A0_011F)).?);
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

        fn fetch32(self: *@This(), address: u32, _: FetchAccess) u32 {
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

        pub fn readData(_: *@This(), comptime T: type, _: u32) T {
            unreachable;
        }

        pub fn writeData(_: *@This(), comptime T: type, _: u32, _: T) void {
            unreachable;
        }

        pub fn fetch16(_: *@This(), _: u32, _: FetchAccess) u16 {
            unreachable;
        }

        pub fn fetch32(self: *@This(), address: u32, _: FetchAccess) u32 {
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
