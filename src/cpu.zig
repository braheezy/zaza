const std = @import("std");

const Mode = enum(u5) {
    user = 0x10,
    fiq = 0x11,
    irq = 0x12,
    supervisor = 0x13,
    abort = 0x17,
    undefined_instruction = 0x1B,
    system = 0x1F,
    _,
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
    if (self.cpsr & thumb_bit != 0) {
        return self.stepQueuedThumb(bus);
    }
    return self.stepArm(bus);
}

pub fn inArmState(self: *const Cpu) bool {
    return self.cpsr & thumb_bit == 0;
}

pub fn stepQueuedThumb(self: *Cpu, bus: anytype) error{ PipelineNotReady, UnsupportedInstruction }!void {
    const queued = self.pipeline orelse return error.PipelineNotReady;
    return self.stepThumb(bus, @truncate(queued[0]));
}

pub fn stepArm(self: *Cpu, bus: anytype) error{ PipelineNotReady, UnsupportedInstruction }!void {
    const queued = self.pipeline orelse return error.PipelineNotReady;
    const instruction = queued[0];
    const key: u8 = @truncate(instruction >> 20);
    return ArmDispatch(@TypeOf(bus)).table[key](self, bus, instruction);
}

// Bits 27..20 encode the ALU operation and operand form. Other families
// share a handler and use the full instruction for their addressing fields.
fn ArmDispatch(comptime BusPtr: type) type {
    return struct {
        const Handler = *const fn (*Cpu, BusPtr, u32) error{UnsupportedInstruction}!void;
        const table = blk: {
            @setEvalBranchQuota(5000);
            var handlers: [256]Handler = undefined;
            for (&handlers, 0..) |*entry, key| {
                entry.* = switch (key) {
                    0x00...0x3f => dataHandler(@intCast(key)),
                    0x40...0x7f => transfer,
                    0x80...0x9f => blockTransfer,
                    0xa0...0xbf => branch,
                    0xc0...0xef => coprocessor,
                    else => swi,
                };
            }
            break :blk handlers;
        };

        fn dataHandler(comptime key: u8) Handler {
            return &struct {
                fn run(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
                    // Unconditional ADD immediate can write an ordinary register and advance directly.
                    if (key == 0x28 and instruction >> 28 == 0xe) {
                        const destination: u4 = @truncate(instruction >> 12);
                        if (destination != program_counter) {
                            const base = cpu.readRegister(@truncate(instruction >> 16));
                            cpu.writeGeneralRegister(destination, base +% armImmediateValue(@truncate(instruction)));
                            _ = cpu.advanceArmPipeline(bus);
                            return;
                        }
                    }
                    // Supply the known opcode bits so the compiler specializes the ALU operation.
                    const word = (instruction & 0xf00f_ffff) | (@as(u32, key) << 20);
                    if (try decodeArmDataProcessing(word)) |decoded| {
                        cpu.stepArmDataProcessing(bus, decoded);
                    } else try cpu.stepArmMisc(bus, instruction);
                }
            }.run;
        }

        fn transfer(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
            return cpu.executeArmTransfer(bus, instruction, false);
        }

        fn blockTransfer(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
            return cpu.executeArmBlockTransfer(bus, instruction);
        }

        fn branch(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
            const condition: u4 = @truncate(instruction >> 28);
            if (condition == 0xF) return error.UnsupportedInstruction;
            cpu.executeArmBranch(bus, instruction, condition);
        }

        fn swi(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
            const condition: u4 = @truncate(instruction >> 28);
            if (condition == 0xF) return error.UnsupportedInstruction;
            cpu.executeArmSwi(bus, condition);
        }

        fn coprocessor(cpu: *Cpu, bus: BusPtr, instruction: u32) error{UnsupportedInstruction}!void {
            const condition: u4 = @truncate(instruction >> 28);
            if (condition == 0xF) return error.UnsupportedInstruction;
            _ = cpu.advanceArmPipeline(bus);
            if (conditionPassed(condition, cpu.readFlags()))
                cpu.enterException(bus, .undefined_instruction, 0x04, cpu.instruction_address);
        }
    };
}

// These encodings overlap data processing and require additional opcode bits.
noinline fn stepArmMisc(self: *Cpu, bus: anytype, instruction: u32) error{UnsupportedInstruction}!void {
    if (instruction & 0x0FFF_FFF0 == 0x012F_FF10) {
        try self.executeArmBx(bus, instruction);
        return;
    }
    if (instruction & 0x0FBF_0FFF == 0x010F_0000) {
        try self.executeArmMrs(bus, instruction);
        return;
    }
    if (instruction & 0x0FB0_FFF0 == 0x0120_F000 or
        instruction & 0x0FB0_F000 == 0x0320_F000)
    {
        try self.executeArmMsr(bus, instruction);
        return;
    }
    if (instruction & 0x0FB0_0FF0 == 0x0100_0090) {
        try self.executeArmSwap(bus, instruction);
        return;
    }
    // Multiply encodings overlap the data-processing space.
    if (instruction & 0x0FC0_00F0 == 0x0000_0090 or instruction & 0x0F80_00F0 == 0x0080_0090) {
        if (instruction >> 28 == 15) return error.UnsupportedInstruction;
        // The multiplier samples operands after the sequential fetch (R15 = PC + 12).
        _ = self.advanceArmPipeline(bus);
        if (self.executeArmMultiply(instruction)) |target| {
            self.instruction_address = target & ~@as(u32, 3);
            self.refillArmPipeline(bus);
        }
        return;
    }
    if (isArmExtraTransfer(instruction))
        return self.executeArmTransfer(bus, instruction, true);
    return error.UnsupportedInstruction;
}

inline fn stepArmDataProcessing(self: *Cpu, bus: anytype, decoded: ArmDataProcessing) void {
    if (decoded.condition != 0xE and !conditionPassed(decoded.condition, self.readFlags())) {
        _ = @call(.never_inline, advanceArmPipeline, .{ self, bus });
        return;
    }
    const redirect = self.executeArmDataProcessing(decoded);
    _ = @call(.never_inline, advanceArmPipeline, .{ self, bus });
    if (decoded.destination == program_counter) self.finishArmAluPc(bus, decoded.set_flags, redirect);
}

// PC and status writes share the same rare refill path across ALU handlers.
noinline fn finishArmAluPc(self: *Cpu, bus: anytype, set_flags: bool, redirect: ?u32) void {
    // In User and System modes this reads back the flags the ALU just wrote.
    if (set_flags) self.cpsr = self.readSpsr();
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
    // Both address and store data see PC + 12 after the sequential fetch.
    _ = self.advanceArmPipeline(bus);
    const address = self.readRegister(base);
    const outgoing = self.readRegister(source);

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
    if (destination == program_counter) {
        self.instruction_address = incoming & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    } else {
        self.writeGeneralRegister(destination, incoming);
    }
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
    var registers: u16 = @truncate(instruction);
    // An empty list transfers PC but moves the base by sixteen words.
    const count: u32 = if (registers == 0) 16 else @popCount(registers);
    if (registers == 0) registers = 1 << program_counter;

    const loads_pc = load and registers & (1 << program_counter) != 0;
    const return_status = if (special and loads_pc) self.readSpsr() else null;
    const user_bank = special and !loads_pc;

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
        if (base_register == program_counter) {
            target = updated_base;
        } else if (user_bank) {
            self.registers[base_register] = updated_base;
        } else {
            self.writeGeneralRegister(base_register, updated_base);
        }
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

    const transfer = try self.decodeArmTransfer(instruction, extra);
    _ = self.advanceArmPipeline(bus);
    self.finishArmTransfer(bus, transfer);
}

fn isArmExtraTransfer(word: u32) bool {
    // Bits 6..5 distinguish these transfers from multiply and swap.
    return word & 0x0E00_0090 == 0x0000_0090 and word & 0x60 != 0;
}

const ArmTransfer = struct {
    const Operation = enum {
        word,
        byte,
        halfword,
        signed_byte,
        signed_halfword,

        fn Data(comptime op: Operation) type {
            return switch (op) {
                .word => u32,
                .halfword, .signed_halfword => u16,
                .byte, .signed_byte => u8,
            };
        }

        fn loadValue(comptime op: Operation, value: op.Data(), address: u32) u32 {
            return switch (op) {
                .word, .halfword => std.math.rotr(u32, value, (address & (@sizeOf(op.Data()) - 1)) * 8),
                .byte => value,
                .signed_byte => signExtendByte(value),
                .signed_halfword => signedHalfwordValue(value, address),
            };
        }
    };

    operation: Operation,
    address: u32,
    updated_base: u32,
    base_register: u4,
    data_register: u4,
    load: bool,
    writeback: bool,
};

fn decodeArmTransfer(self: *Cpu, instruction: u32, extra: bool) error{UnsupportedInstruction}!ArmTransfer {
    const pre_index = instruction & (1 << 24) != 0;
    const add = instruction & (1 << 23) != 0;
    const writeback_bit = instruction & (1 << 21) != 0;
    const load = instruction & (1 << 20) != 0;
    const base_register: u4 = @truncate(instruction >> 16);
    const data_register: u4 = @truncate(instruction >> 12);
    const offset_register: u4 = @truncate(instruction);
    // Post-indexed T forms use the same data bus path until it models access privilege.
    const writeback = !pre_index or writeback_bit;

    const operation: ArmTransfer.Operation = if (extra) switch (@as(u2, @truncate(instruction >> 5))) {
        1 => .halfword,
        2 => .signed_byte,
        3 => .signed_halfword,
        else => unreachable,
    } else if (instruction & (1 << 22) != 0) .byte else .word;

    const offset: u32 = if (extra) blk: {
        if (!load and operation != .halfword) return error.UnsupportedInstruction;
        if (instruction & (1 << 22) != 0) {
            break :blk ((instruction >> 4) & 0xF0) | (instruction & 0xF);
        }
        // Register offsets consume Rm only; bits 11–8 do not contribute.
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
    return .{
        .operation = operation,
        .address = address,
        .updated_base = updated_base,
        .base_register = base_register,
        .data_register = data_register,
        .load = load,
        .writeback = writeback,
    };
}

fn finishArmTransfer(self: *Cpu, bus: anytype, transfer: ArmTransfer) void {
    if (!transfer.load) {
        // A store of R15 sees the PC after the sequential fetch (instruction + 12).
        const value = self.readRegister(transfer.data_register);
        switch (transfer.operation) {
            .word => bus.writeData(u32, transfer.address, value),
            .byte => bus.writeData(u8, transfer.address, @truncate(value)),
            .halfword => bus.writeData(u16, transfer.address, @truncate(value)),
            .signed_byte, .signed_halfword => unreachable,
        }
        if (transfer.writeback) self.writeTransferBase(bus, transfer.base_register, transfer.updated_base);
        return;
    }

    const value = switch (transfer.operation) {
        inline else => |op| op.loadValue(bus.readData(op.Data(), transfer.address), transfer.address),
    };
    // The load completes with an internal cycle before the result is available.
    self.internal_cycles += 1;
    if (transfer.writeback and transfer.base_register != transfer.data_register) {
        self.writeTransferBase(bus, transfer.base_register, transfer.updated_base);
    }
    if (transfer.data_register == program_counter) {
        self.instruction_address = value & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    } else {
        self.writeGeneralRegister(transfer.data_register, value);
    }
}

fn writeTransferBase(self: *Cpu, bus: anytype, base: u4, updated: u32) void {
    if (base == program_counter) {
        // Address generation saw PC + 8. Writeback sees PC + 12 after the fetch.
        self.instruction_address = (updated +% 4) & ~@as(u32, 3);
        self.refillArmPipeline(bus);
    } else {
        self.writeGeneralRegister(base, updated);
    }
}

// Bits 15..6 identify every Thumb operation. Ignore operand bits within that
// index so entries for different registers or offsets share the same handler.
fn thumbOpcode(bits: u16) u16 {
    return switch (bits) {
        0x1800...0x1fff, 0x5000...0x5fff => bits & 0xfe00,
        0x4000...0x43ff => bits & 0xffc0,
        0x4400...0x47ff, 0xb000...0xbfff, 0xd000...0xdfff => bits & 0xff00,
        else => bits & 0xf800,
    };
}

fn ThumbDispatch(comptime BusPtr: type) type {
    return struct {
        const Handler = *const fn (*Cpu, BusPtr, u16) error{UnsupportedInstruction}!void;
        const table = blk: {
            @setEvalBranchQuota(20000);
            var handlers: [1024]Handler = undefined;
            for (&handlers, 0..) |*entry, index| {
                entry.* = handler(thumbOpcode(@as(u16, @intCast(index)) << 6));
            }
            break :blk handlers;
        };

        fn handler(comptime opcode: u16) Handler {
            return &struct {
                fn run(cpu: *Cpu, bus: BusPtr, instruction: u16) error{UnsupportedInstruction}!void {
                    return cpu.stepThumbDecoded(bus, opcode, instruction);
                }
            }.run;
        }
    };
}

const InstructionRun = struct { steps: usize = 0, cycles: u64 = 0 };

/// In IWRAM each instruction fetch costs one cycle, including both words of a branch refill.
pub fn runArmIwram(self: *Cpu, bus: anytype, limit: usize, budget: u64) InstructionRun {
    var queue = self.pipeline orelse return .{};
    var run: InstructionRun = .{};
    const internal_before = self.internal_cycles;
    while (run.steps < limit and run.cycles < budget) {
        const pc = self.instruction_address;
        const fetch = pc +% 8;
        if (fetch >> 24 != 3) break;
        const word = queue[0];
        const condition: u4 = @truncate(word >> 28);
        if (condition == 0xF) break;
        const execute = condition == 0xE or conditionPassed(condition, self.readFlags());
        // A store may replace the word being fetched. The pipeline sees its old contents.
        const next = bus.iwramWord(fetch);
        if (word & 0x0E00_0000 == 0x0A00_0000) {
            if (execute) {
                const target = armBranchTarget(pc, word);
                if (target >> 24 != 3 or (target +% 4) >> 24 != 3 or budget - run.cycles < 3) break;
                if (word & (1 << 24) != 0) self.writeGeneralRegister(link_register, pc + 4);
                queue = .{ bus.iwramWord(target), bus.iwramWord(target + 4) };
                self.instruction_address = target;
                run.cycles += 3;
                run.steps += 1;
                continue;
            }
        } else if (word & 0x0C00_0000 == 0x0400_0000) {
            if (execute) {
                const data_budget = budget - run.cycles - 1;
                const cycles = @call(.always_inline, runArmRamTransfer, .{
                    self, bus, word, false, data_budget,
                });
                run.cycles += cycles orelse break;
            }
        } else if (decodeArmDataProcessing(word) catch break) |decoded| {
            if (decoded.registerShift() or decoded.destination == program_counter) break;
            if (execute) _ = self.executeArmDataProcessing(decoded);
        } else if (isArmExtraTransfer(word)) {
            if (execute) {
                const data_budget = budget - run.cycles - 1;
                // Keep the less frequent halfword and signed handlers out of the hot loop.
                const cycles = @call(.never_inline, runArmRamTransfer, .{
                    self, bus, word, true, data_budget,
                });
                run.cycles += cycles orelse break;
            }
        } else break;
        queue = .{ queue[1], next };
        self.instruction_address = pc + 4;
        run.cycles += 1;
        run.steps += 1;
    }
    if (run.steps != 0) {
        self.pipeline = queue;
        const internal = self.internal_cycles - internal_before;
        bus.finishIwramRun(run.cycles - internal, internal, queue[1]);
    }
    return run;
}

fn runArmRamTransfer(
    self: *Cpu,
    bus: anytype,
    word: u32,
    comptime extra: bool,
    budget: u64,
) ?u64 {
    const transfer = @call(.always_inline, decodeArmTransfer, .{ self, word, extra }) catch return null;
    if (transfer.data_register == program_counter or
        (transfer.writeback and transfer.base_register == program_counter)) return null;
    return switch (transfer.operation) {
        inline else => |op| self.transferWorkRam(bus, transfer, op, budget),
    };
}

// Check both the RAM mapping and the deadline before changing registers or memory.
inline fn transferWorkRam(
    self: *Cpu,
    bus: anytype,
    transfer: ArmTransfer,
    comptime op: ArmTransfer.Operation,
    budget: u64,
) ?u64 {
    const T = op.Data();
    const aligned = transfer.address & ~@as(u32, @sizeOf(T) - 1);
    const bytes = bus.workRamBytes(T, aligned) orelse return null;
    const region: u8 = @truncate(transfer.address >> 24);
    const data_cycles = @import("timing.zig").ramAccessCycles(T, region);
    const internal: u64 = @intFromBool(transfer.load);
    const cycles = data_cycles + internal;
    if (cycles > budget) return null;
    if (transfer.load) {
        const value = std.mem.readInt(T, bytes, .little);
        self.writeGeneralRegister(transfer.data_register, op.loadValue(value, transfer.address));
    } else {
        std.mem.writeInt(T, bytes, @truncate(self.readRegister(transfer.data_register)), .little);
    }
    if (transfer.writeback and (!transfer.load or transfer.base_register != transfer.data_register))
        self.writeGeneralRegister(transfer.base_register, transfer.updated_base);
    if (region == 3) bus.iwram_data_cycles += data_cycles;
    self.internal_cycles += internal;
    return cycles;
}

/// Execute arithmetic from the live pipeline while sequential fetch timing is constant.
pub fn runRomAluSpan(self: *Cpu, bus: anytype, comptime T: type, limit: usize, cycles_left: u64) InstructionRun {
    var queue = self.pipeline orelse return .{ .steps = 0, .cycles = 0 };
    // In ROM, setting up a timed span only pays off across successive ALU operations.
    if (T == u32 and (queue[0] | queue[1]) & 0x0C00_0000 != 0) return .{ .steps = 0, .cycles = 0 };
    const width = @sizeOf(T);
    const span = bus.romFetchSpan(T, self.instruction_address + 2 * width);
    const count_limit = @min(limit, span.bytes.len / width, cycles_left / span.cycles_per_fetch);
    var count: usize = 0;
    while (count < count_limit) : (count += 1) {
        const word = queue[0];
        if (T == u32) {
            const decoded = (decodeArmDataProcessing(word) catch break) orelse break;
            if (decoded.registerShift() or decoded.destination == program_counter) break;
            if (decoded.condition == 0xE or conditionPassed(decoded.condition, self.readFlags())) {
                _ = self.executeArmDataProcessing(decoded);
            }
        } else {
            if (word >= 0x4000) break;
            const op: u16 = @intCast(word);
            self.executeThumbLowAlu(op, op) catch unreachable;
        }
        queue = .{ queue[1], std.mem.readInt(T, span.bytes[count * width ..][0..width], .little) };
        self.instruction_address += width;
    }
    const cycles = count * @as(u64, span.cycles_per_fetch);
    if (count != 0) {
        self.pipeline = queue;
        bus.finishRomFetchSpan(T, cycles, self.instruction_address + 2 * width, queue[1]);
    }
    return .{ .steps = count, .cycles = cycles };
}

/// Run Thumb arithmetic, stable reads and short branches up to a device event.
/// The admitted instructions can change PC, the pipeline, flags and low registers.
pub fn runReadOnlyThumbUntil(self: *Cpu, bus: anytype, limit: usize, deadline: u64) struct {
    instructions: usize,
    cycles: u64,
    edge_cycles: u64,
} {
    const start_pc = self.instruction_address;
    const registers = self.registers[0..8].*;
    const flags = self.cpsr;
    const pipeline = self.pipeline;
    const fifo = bus.cartridge_prefetch;
    const latch = bus.prefetch_word;
    const nonsequential = bus.next_fetch_nonsequential;
    const start_bus = bus.bus_cycles;
    const start_internal = self.internal_cycles;
    const start_rom = bus.rom_fetch_cycles;
    const start_iwram = bus.iwram_data_cycles;
    var count: usize = 0;
    var cycles: u64 = 0;
    var last: u64 = 0;
    while (count < limit and cycles < deadline) {
        // Leave room for either branch displacement and its pipeline refill.
        if (self.instruction_address < 0x0800_0800 or self.instruction_address >= 0x0DFF_F7FC) break;
        const queued = self.pipeline orelse break;
        const op: u16 = @truncate(queued[0]);
        if ((queued[0] | queued[1]) < 0x4000) {
            const span = self.runRomAluSpan(bus, u16, limit - count, deadline - cycles - 1);
            if (span.steps != 0) {
                count += span.steps;
                cycles += span.cycles;
                continue;
            }
        }
        const before = self.internal_cycles;
        if (!self.stepReadOnlyThumb(bus, op, deadline - cycles)) break;
        const internal = self.internal_cycles - before;
        if (internal != 0) {
            bus.next_fetch_nonsequential = true;
            bus.cartridge_prefetch.advance(internal);
        }
        count += 1;
        const elapsed = (bus.bus_cycles - start_bus) + (self.internal_cycles - start_internal);
        last = elapsed - cycles;
        cycles = elapsed;

        // A read-only loop with identical operands, pipeline and fetch timing
        // repeats exactly until the first device event or instruction budget.
        if (self.instruction_address == start_pc and cycles < deadline and
            self.cpsr == flags and std.mem.eql(u32, self.registers[0..8], &registers) and
            std.meta.eql(self.pipeline, pipeline) and std.meta.eql(bus.cartridge_prefetch, fifo) and
            bus.next_fetch_nonsequential == nonsequential and bus.prefetch_word == latch)
        {
            const repeats = @min((deadline - 1 - cycles) / cycles, (limit - count) / count);
            bus.bus_cycles += (bus.bus_cycles - start_bus) * repeats;
            bus.rom_fetch_cycles += (bus.rom_fetch_cycles - start_rom) * repeats;
            bus.iwram_data_cycles += (bus.iwram_data_cycles - start_iwram) * repeats;
            self.internal_cycles += (self.internal_cycles - start_internal) * repeats;
            count += count * repeats;
            cycles += cycles * repeats;
        }
    }
    if (count != 0) {
        bus.cpu_internal_cycles += self.internal_cycles - start_internal;
        bus.dma_bus_word = null;
    }
    return .{ .instructions = count, .cycles = cycles, .edge_cycles = if (cycles >= deadline) last else 0 };
}

// RAM and display status remain stable until the deadline in this read-only run.
// A rejected instruction is left queued for the normal timed interpreter.
inline fn stepReadOnlyThumb(self: *Cpu, bus: anytype, op: u16, cycles_left: u64) bool {
    switch (op >> 11) {
        0...7, 28 => self.stepThumb(bus, op) catch unreachable,
        8 => {
            if (op >= 0x4400) return false; // High registers can redirect PC.
            self.stepThumb(bus, op) catch unreachable;
        },
        26, 27 => {
            if (op >= 0xDE00) return false; // Reserved condition or SWI.
            self.stepThumb(bus, op) catch unreachable;
        },
        13, 15, 17 => {
            const transfer = self.decodeThumbTransfer(op, op).?;
            const region = transfer.address >> 24;
            if (region == 2 or region == 3) {
                self.advanceThumbPipeline(bus, self.instruction_address + 4);
                self.executeThumbTransfer(bus, transfer);
            } else {
                if (transfer.operation != .ldrh or !@TypeOf(bus.*).canReadStableDisplay(transfer.address, cycles_left)) return false;
                self.advanceThumbPipeline(bus, self.instruction_address + 4);
                self.finishThumbLoad(transfer.register, bus.readStableDisplay(transfer.address));
            }
        },
        else => return false,
    }
    return true;
}

fn stepThumb(self: *Cpu, bus: anytype, instruction: u16) error{UnsupportedInstruction}!void {
    return ThumbDispatch(@TypeOf(bus)).table[instruction >> 6](self, bus, instruction);
}

inline fn stepThumbDecoded(self: *Cpu, bus: anytype, comptime opcode: u16, instruction: u16) error{UnsupportedInstruction}!void {
    const pc = self.instruction_address +% 4;
    if (self.decodeThumbTransfer(opcode, instruction)) |transfer| {
        self.advanceThumbPipeline(bus, pc);
        self.executeThumbTransfer(bus, transfer);
        return;
    }
    const stack_transfer = opcode & 0xF600 == 0xB400;
    if (stack_transfer or opcode >> 12 == 0xC) {
        self.advanceThumbPipeline(bus, pc);
        self.executeThumbBlockTransfer(bus, instruction, stack_transfer);
        return;
    }
    const immediate: u11 = @truncate(instruction);
    const signed_immediate: i32 = @as(i11, @bitCast(immediate));
    var target: ?u32 = null;
    const software_interrupt = opcode >> 8 == 0xDF;
    // BX consumes only the source register field in the Thumb high-register format.
    const exchange = opcode >> 8 == 0x47;
    if (software_interrupt) {
        // Exception entry runs after the sequential Thumb fetch.
    } else if (exchange) {
        const source: u4 = @truncate(instruction >> 3);
        target = self.readRegister(source);
    } else if (opcode >> 10 == 0b010001) {
        target = try self.executeThumbHighAlu(opcode, instruction);
    } else if (opcode >> 12 == 0xD) {
        const condition: u4 = @truncate(opcode >> 8);
        // The pinned ARM7TDMI vectors take the reserved 0xE condition as AL.
        if (conditionPassed(condition, self.readFlags())) {
            const displacement: i8 = @bitCast(@as(u8, @truncate(instruction)));
            target = pc +% @as(u32, @bitCast(@as(i32, displacement) * 2));
        }
    } else switch (opcode >> 11) {
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
        else => try self.executeThumbLowAlu(opcode, instruction),
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

inline fn decodeThumbTransfer(self: *Cpu, opcode: u16, instruction: u16) ?ThumbTransfer {
    const low_register: u3 = @truncate(instruction);
    const high_register: u3 = @truncate(instruction >> 8);
    const base_register: u3 = @truncate(instruction >> 3);
    const offset: u32 = @as(u5, @truncate(instruction >> 6));
    const load = opcode & (1 << 11) != 0;
    const offset_word = @as(u32, @as(u8, @truncate(instruction))) * 4;
    return switch (opcode >> 12) {
        4 => if (load) .{
            .operation = .ldr,
            .address = (self.readRegister(program_counter) & ~@as(u32, 3)) +% offset_word,
            .register = high_register,
        } else null,
        5 => .{
            .operation = @enumFromInt(@as(u3, @truncate(opcode >> 9))),
            .address = self.readRegister(base_register) +% self.readRegister(@as(u3, @truncate(instruction >> 6))),
            .register = low_register,
        },
        6, 7, 8 => blk: {
            const width: u32 = switch (opcode >> 12) {
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
        .ldrsh => signedHalfwordValue(bus.readData(u16, address), address),
    };
    self.finishThumbLoad(register, result);
}

inline fn finishThumbLoad(self: *Cpu, register: u3, result: u32) void {
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

fn signedHalfwordValue(value: u16, address: u32) u32 {
    // An odd address selects and sign-extends the upper byte of the halfword.
    if (address & 1 != 0) return signExtendByte(@truncate(value >> 8));
    return @bitCast(@as(i32, @as(i16, @bitCast(value))));
}

fn signExtendByte(value: u8) u32 {
    return @bitCast(@as(i32, @as(i8, @bitCast(value))));
}

inline fn executeThumbHighAlu(self: *Cpu, comptime opcode: u16, instruction: u16) error{UnsupportedInstruction}!?u32 {
    const operation: u2 = @truncate(opcode >> 8);
    if (operation == 3) return error.UnsupportedInstruction;
    const source: u4 = @truncate(instruction >> 3);
    const destination: u4 = (@as(u4, @truncate(instruction >> 4)) & 8) |
        @as(u3, @truncate(instruction));
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
    if (@hasDecl(@TypeOf(bus.*), "fetchThumbPair")) {
        self.pipeline = bus.fetchThumbPair(self.instruction_address);
        return;
    }
    const current = bus.fetch16(self.instruction_address, .nonsequential);
    const next = bus.fetch16(self.instruction_address +% 2, .sequential);
    self.pipeline = .{ current, next };
}

inline fn executeThumbLowAlu(self: *Cpu, opcode: u16, instruction: u16) error{UnsupportedInstruction}!void {
    if (opcode >> 10 == 0b010000) {
        self.executeThumbRegisterAlu(opcode, instruction);
        return;
    }
    if (opcode >> 12 == 0b1010) {
        const destination: u3 = @truncate(instruction >> 8);
        const offset = @as(u32, @as(u8, @truncate(instruction))) * 4;
        // Thumb PC-relative address generation uses a word-aligned PC.
        const base = if (opcode & (1 << 11) != 0)
            self.readRegister(stack_pointer)
        else
            self.readRegister(program_counter) & ~@as(u32, 3);
        self.writeGeneralRegister(destination, base +% offset);
        return;
    }
    if (opcode >> 8 == 0xB0) {
        const offset = @as(u32, @as(u7, @truncate(instruction))) * 4;
        const base = self.readRegister(stack_pointer);
        const result = if (instruction & (1 << 7) != 0) base -% offset else base +% offset;
        self.writeGeneralRegister(stack_pointer, result);
        return;
    }
    switch (opcode >> 13) {
        0b000 => {
            const destination: u3 = @truncate(instruction);
            const source: u3 = @truncate(instruction >> 3);
            const kind: u2 = @truncate(opcode >> 11);
            if (kind == 3) {
                const operand: u3 = @truncate(instruction >> 6);
                const right = if (opcode & (1 << 10) != 0)
                    @as(u32, operand)
                else
                    self.readRegister(operand);
                const subtract = opcode & (1 << 9) != 0;
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
            const operation: u2 = @truncate(opcode >> 11);
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

inline fn executeThumbRegisterAlu(self: *Cpu, opcode: u16, instruction: u16) void {
    const operation: u4 = @truncate(opcode >> 6);
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

fn executeArmMultiply(self: *Cpu, instruction: u32) ?u32 {
    const condition: u4 = @truncate(instruction >> 28);
    const left_register: u4 = @truncate(instruction);
    const right_register: u4 = @truncate(instruction >> 8);
    const lower_register: u4 = @truncate(instruction >> 12);
    const upper_register: u4 = @truncate(instruction >> 16);
    const long = instruction & (1 << 23) != 0;
    const accumulate = instruction & (1 << 21) != 0;
    var flags = self.readFlags();
    if (!conditionPassed(condition, flags)) return null;
    const left = self.readRegister(left_register);
    const right = self.readRegister(right_register);
    const signed = !long or instruction & (1 << 22) != 0;
    const iterations = multiplyCycles(right, signed);
    self.internal_cycles += iterations;
    self.internal_cycles += @intFromBool(accumulate);
    var redirect: ?u32 = null;
    const destination_value: u32 = if (long) result_word: {
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
        // Low writes first, so the high word wins when both destinations alias.
        const low: u32 = @truncate(result);
        if (lower_register == program_counter) {
            redirect = low;
        } else {
            self.writeGeneralRegister(lower_register, low);
        }
        flags.negative = result >> 63 != 0;
        flags.zero = result == 0;
        break :result_word @truncate(result >> 32);
    } else result_word: {
        var result = left *% right;
        if (accumulate) result +%= self.readRegister(lower_register);
        flags.negative = result >> 31 != 0;
        flags.zero = result == 0;
        break :result_word result;
    };
    if (upper_register == program_counter) {
        redirect = destination_value;
    } else {
        self.writeGeneralRegister(upper_register, destination_value);
    }
    if (instruction & (1 << 20) != 0) self.writeFlags(flags);
    return redirect;
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
        try std.testing.expectEqual(@as(?u32, null), cpu.executeArmMultiply(0xE0F3_2190)); // SMLALS r2, r3, r0, r1
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
    try std.testing.expectEqual(@as(?u32, null), cpu.executeArmMultiply(0xE024_0194)); // MLA r4, r4, r1, r0
    try std.testing.expectEqual(@as(u32, 18_296), cpu.registers[4]);
    try std.testing.expectEqual(@as(u64, 2), cpu.internal_cycles);

    // Both words of the long accumulator and the aliased multiplicand use their old values.
    cpu.registers[0] = 0xFFFF_FFFF;
    cpu.registers[1] = 7;
    cpu.registers[2] = 2;
    try std.testing.expectEqual(@as(?u32, null), cpu.executeArmMultiply(0xE0A1_0290)); // UMLAL r0, r1, r0, r2
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), cpu.registers[0]);
    try std.testing.expectEqual(@as(u32, 9), cpu.registers[1]);

    cpu.registers[0] = 0xFFFF_FFFF;
    cpu.registers[1] = 7;
    try std.testing.expectEqual(@as(?u32, null), cpu.executeArmMultiply(0xE0A1_0291)); // UMLAL r0, r1, r1, r2
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
    self.instruction_address = armBranchTarget(address, instruction);
    self.refillArmPipeline(bus);
}

fn armBranchTarget(address: u32, instruction: u32) u32 {
    const words: i24 = @bitCast(@as(u24, @truncate(instruction)));
    const offset: u32 = @bitCast(@as(i32, words) * 4);
    return address +% 8 +% offset;
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

fn executeArmMrs(self: *Cpu, bus: anytype, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    const destination: u4 = @truncate(instruction >> 12);
    if (condition == 0xF) return error.UnsupportedInstruction;
    _ = self.advanceArmPipeline(bus);
    if (!conditionPassed(condition, self.readFlags())) return;

    const value = if (instruction & (1 << 22) != 0) self.readSpsr() else self.cpsr;
    if (destination == program_counter) {
        // MRS writes R15 before its final increment, retaining the prefetched words.
        self.instruction_address = (value & ~@as(u32, 3)) -% 4;
    } else self.writeGeneralRegister(destination, value);
}

fn executeArmMsr(self: *Cpu, bus: anytype, instruction: u32) error{UnsupportedInstruction}!void {
    const condition: u4 = @truncate(instruction >> 28);
    if (condition == 0xF) return error.UnsupportedInstruction;

    const value = if (instruction & (1 << 25) != 0) blk: {
        const immediate: u8 = @truncate(instruction);
        const rotation: u4 = @truncate(instruction >> 8);
        break :blk std.math.rotr(u32, immediate, @as(u5, rotation) * 2);
    } else self.readRegister(@truncate(instruction));
    _ = self.advanceArmPipeline(bus);
    if (!conditionPassed(condition, self.readFlags())) return;
    const fields: u4 = @truncate(instruction >> 16);
    var mask: u32 = 0;
    for (0..4) |field| {
        if (fields & (@as(u4, 1) << @as(u2, @intCast(field))) != 0) {
            mask |= @as(u32, 0xFF) << @as(u5, @intCast(field * 8));
        }
    }
    if (instruction & (1 << 22) != 0) {
        const index = self.savedStatusIndex() orelse return;
        self.spsr[index] = (self.spsr[index] & ~mask) | (value & mask);
        return;
    }
    // User mode can write only the selected flags byte, not the control bytes.
    if (self.mode() == .user) mask &= 0xFF00_0000;
    // ARM7TDMI holds the high bit of the five-bit mode field set.
    self.cpsr = (self.cpsr & ~mask) | ((value | 0x10) & mask);
    // Keep the visible R15 and the two fetched ARM words if MSR sets T.
    if (self.cpsr & thumb_bit != 0) self.instruction_address +%= 4;
}

fn readSpsr(self: *Cpu) u32 {
    // User and System read CPSR when no saved status register is selected.
    return switch (self.mode()) {
        .user, .system => self.cpsr,
        else => (self.savedStatus() orelse 0) | 0x10,
    };
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
        else => null,
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

inline fn armImmediateValue(operand: u12) u32 {
    const rotation: u5 = @as(u5, @intCast(operand >> 8)) * 2;
    return std.math.rotr(u32, @as(u8, @truncate(operand)), rotation);
}

inline fn decodeArmDataProcessing(instruction: u32) error{UnsupportedInstruction}!?ArmDataProcessing {
    const decoded: ArmDataProcessing = @bitCast(instruction);
    if (decoded.family != 0) return null;
    // Test opcodes with S clear share space with status transfers and BX.
    switch (decoded.operation) {
        .tst, .teq, .cmp, .cmn => if (!decoded.set_flags) return null,
        else => {},
    }
    if (decoded.registerShift() and decoded.operand & 0x80 != 0) return null; // Multiply or extra transfer.
    if (decoded.condition == 0xF) return error.UnsupportedInstruction;
    if ((decoded.operation == .mov or decoded.operation == .mvn) and decoded.source != 0)
        return error.UnsupportedInstruction;
    return decoded;
}

// Return a redirect instead of writing PC so step can preserve fetch ordering.
inline fn executeArmDataProcessing(self: *Cpu, decoded: ArmDataProcessing) ?u32 {
    const old_flags = self.readFlags();
    const register_shift = decoded.registerShift();
    const operand: ShifterResult = if (decoded.immediate) blk: {
        const value = armImmediateValue(decoded.operand);
        break :blk .{ .value = value, .carry = if (decoded.operand >> 8 == 0) old_flags.carry else value >> 31 != 0 };
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
    var redirect: ?u32 = null;
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
                    if (destination == program_counter) {
                        redirect = result;
                    } else self.writeGeneralRegister(destination, result);
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
                    if (destination == program_counter) {
                        redirect = result.value;
                    } else self.writeGeneralRegister(destination, result.value);
                },
            }
            if (decoded.set_flags) self.writeFlags(result.flags);
        },
    }
    return redirect;
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
fn activeBank(self: *Cpu) ?[]u32 {
    return switch (self.mode()) {
        .user, .system => self.registers[15..15],
        .fiq => &self.banked.fiq,
        .supervisor => &self.banked.supervisor,
        .abort => &self.banked.abort,
        .irq => &self.banked.irq,
        .undefined_instruction => &self.banked.undefined_instruction,
        else => null,
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
        const bank = self.activeBank() orelse return 0;
        const first = 15 - bank.len;
        if (index >= first) return bank[index - first];
    }
    return self.registers[index];
}

fn writeGeneralRegister(self: *Cpu, index: u4, value: u32) void {
    // PC writes must go through the control-flow path.
    std.debug.assert(index < program_counter);
    if (index >= 8) {
        const bank = self.activeBank() orelse return;
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
    // MOV r0, pc, LSL pc reads the count at PC + 8 and the value at PC + 12.
    const before = cpu.internal_cycles;
    _ = cpu.executeArmDataProcessing((try decodeArmDataProcessing(0xE1A0_0F1F)).?);
    try std.testing.expectEqual(@as(u32, 0xC00), cpu.registers[0]);
    try std.testing.expectEqual(before + 1, cpu.internal_cycles);
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
