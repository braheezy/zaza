const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();
const video = @import("video.zig");
const mode0 = @import("mode0.zig");
const timing = @import("timing.zig");
const input = @import("input.zig");
const SaveMemory = @import("save_memory.zig");

cpu: Cpu,
bus: Bus,
elapsed_cycles: u64 = 0,
dma_cycles_pending: u64 = 0,
mode0_frame: video.Frame = undefined,
mode0_lines: usize = 0,
mode0_frame_number: ?u64 = null,

const vblank_start = timing.vblank_start;

// Start directly at the cartridge entry point without running the BIOS.
pub fn initCartridge(self: *Machine, rom: []const u8) void {
    self.* = .{
        .cpu = .{ .instruction_address = Bus.rom_base },
        .bus = .{ .rom = rom, .save = .{ .kind = SaveMemory.Kind.detect(rom) } },
    };
    self.cpu.refillArmPipeline(&self.bus);
}

pub fn initCartridgeWithBios(
    self: *Machine,
    rom: []const u8,
    bios: *const [Bus.bios_size_bytes]u8,
) void {
    self.initCartridge(rom);
    self.bus.bios = bios;
    // Fast boot skips the BIOS routine that initializes the banked stacks.
    self.cpu.cpsr = 0x1F; // System mode, ARM state.
    self.cpu.registers[13] = 0x0300_7F00;
    self.cpu.banked.irq[0] = 0x0300_7FA0;
    self.cpu.banked.supervisor[0] = 0x0300_7FE0;
    self.bus.post_boot = true;
}

pub fn initBios(self: *Machine, rom: []const u8, bios: *const [Bus.bios_size_bytes]u8) void {
    self.* = .{
        .cpu = .{},
        .bus = .{
            .rom = rom,
            .save = .{ .kind = SaveMemory.Kind.detect(rom) },
            .bios = bios,
            .dispcnt = 0x0080,
        },
    };
    self.cpu.refillArmPipeline(&self.bus);
}

pub fn step(self: *Machine) !void {
    if (self.bus.halted) {
        if (!self.bus.hasEnabledInterrupt()) return;
        self.bus.halted = false;
    }
    // Sample IRQ before executing the next queued instruction.
    if (self.bus.irqLine() and !self.cpu.irqMasked()) {
        if (self.bus.bios == null) return error.IrqNeedsBios;
        self.bus.dma_bus_word = null;
        self.cpu.enterIrq(&self.bus);
        return;
    }
    // BIOS data visibility depends on the executing instruction, not lookahead fetches.
    self.bus.executing_bios = self.cpu.instruction_address < Bus.bios_size_bytes;
    const result = self.cpu.step(&self.bus);
    self.bus.executing_bios = false;
    try result;
    self.bus.dma_bus_word = null;
    self.bus.runDma(.immediate);
}

/// Advance the clock for one CPU instruction, IRQ entry, or halted interval.
/// Cartridge prefetch hits and contention are not included in the bus costs.
pub fn stepTimed(self: *Machine) !void {
    if (self.dma_cycles_pending != 0) {
        // A display-triggered DMA owns the bus before the CPU can step again.
        const cycles = self.dma_cycles_pending;
        self.dma_cycles_pending = 0;
        self.advanceClock(cycles);
        return;
    }
    if (self.bus.halted) {
        if (self.bus.hasEnabledInterrupt()) {
            // Synchronization and CPU restart both leave the instruction pipeline idle.
            if (self.bus.haltWakeLine()) self.bus.halted = false;
            self.advanceClock(1);
            return;
        }
        const line_phase = self.elapsed_cycles % timing.cycles_per_line;
        const display_cycles = if (line_phase < timing.hblank_start)
            timing.hblank_start - line_phase
        else
            timing.cycles_per_line - line_phase;
        // Timer and display events can wake the CPU. Line boundaries also
        // let runToVBlank stop exactly at its target while the CPU sleeps.
        const timer_cycles = if (self.bus.timer_irq_pending != 0) 1 else self.bus.timers.cyclesUntilOverflow();
        self.advanceClock(@min(display_cycles, timer_cycles));
        return;
    }
    const bus_cycles_before = self.bus.bus_cycles;
    const internal_cycles_before = self.cpu.internal_cycles;
    self.bus.timer_bus_origin = bus_cycles_before;
    defer self.bus.timer_bus_origin = null;
    try self.step();
    self.bus.timer_bus_origin = null;
    const bus_cycles = self.bus.bus_cycles - bus_cycles_before;
    const internal_cycles = self.cpu.internal_cycles - internal_cycles_before;
    self.advanceClock(bus_cycles + internal_cycles);
}

/// Apply a full keypad snapshot and run to the next VBlank for frontends and replay.
pub fn runFrame(self: *Machine, buttons: input.Buttons) !void {
    self.bus.setPressedButtons(buttons);
    // Every timed step advances at least one cycle.
    try self.runToVBlank(timing.cycles_per_frame);
}

/// Stop on the first timed step boundary at or after the next VBlank edge.
pub fn runToVBlank(self: *Machine, instruction_budget: usize) !void {
    const phase = self.elapsed_cycles % timing.cycles_per_frame;
    const target = self.elapsed_cycles + timing.cyclesUntil(
        phase,
        timing.vblank_start,
        timing.cycles_per_frame,
    );
    for (0..instruction_budget) |_| {
        try self.stepTimed();
        if (self.elapsed_cycles >= target) return;
    }
    return error.InstructionBudgetExceeded;
}

fn advanceClock(self: *Machine, cycles: u64) void {
    const old_phase = self.elapsed_cycles % timing.cycles_per_frame;
    self.renderVisibleLines(cycles);
    self.elapsed_cycles += cycles;
    const before_dma = self.bus.bus_cycles;
    self.bus.advanceDevices(old_phase, cycles);
    self.dma_cycles_pending += self.bus.bus_cycles - before_dma;
}

fn renderVisibleLines(self: *Machine, cycles: u64) void {
    const line_phase = self.elapsed_cycles % timing.cycles_per_line;
    const next_hblank = timing.cyclesUntil(line_phase, timing.hblank_start, timing.cycles_per_line);
    const end = self.elapsed_cycles + cycles;
    var edge = self.elapsed_cycles + next_hblank;
    while (edge <= end) : (edge += timing.cycles_per_line) {
        const line = (edge % timing.cycles_per_frame) / timing.cycles_per_line;
        if (line >= video.height) continue;
        if (line == 0) self.mode0_lines = 0;
        if (self.bus.dispcnt & 7 != 0 or self.mode0_lines != line) continue;

        // Sample the visible line before the bus applies HBlank DMA writes.
        self.mode0Display().renderLine(@intCast(line), &self.mode0_frame[line]);
        self.mode0_lines += 1;
        if (self.mode0_lines == video.height) {
            self.mode0_frame_number = edge / timing.cycles_per_frame;
        }
    }
}

test "ARM compare with Rd set to PC restores status and continues sequentially" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0xF0, 0x5F, 0x01, // CMPEQ with Rd = PC, skipped with Z clear.
        0x00, 0xF0, 0x5F, 0xE1, // CMP with Rd = PC, restores the FIQ SPSR.
        0x08, 0x00, 0xA0, 0xE1, // MOV r0, r8
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.cpsr = 0x11;
    machine.cpu.spsr[0] = 0x2000_001F;
    machine.cpu.registers[8] = 32;
    machine.cpu.banked.fiq[0] = 64;

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x11), machine.cpu.cpsr);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x2000_001F), machine.cpu.cpsr);
    try std.testing.expectEqual(Bus.rom_base + 8, machine.cpu.instruction_address);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 32), machine.cpu.readRegister(0));
}

test "ARM word and byte swaps preserve aliased register inputs and charge one internal cycle each" {
    const std = @import("std");
    const rom = [_]u8{
        0x90, 0x00, 0x01, 0xE1, // SWP r0, r0, [r1]
        0x92, 0x10, 0x41, 0xE1, // SWPB r1, r2, [r1]
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = 0x4433_2211;
    machine.cpu.registers[1] = Bus.iwram_base + 1;
    machine.cpu.registers[2] = 0xAABB_CC99;
    machine.bus.writeData(u32, Bus.iwram_base, 0xDDCC_BBAA);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0xAADD_CCBB), machine.cpu.readRegister(0));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), machine.bus.readData(u32, Bus.iwram_base));
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x22), machine.cpu.readRegister(1));
    try std.testing.expectEqual(@as(u32, 0x4433_9911), machine.bus.readData(u32, Bus.iwram_base));
    try std.testing.expectEqual(@as(u64, 2), machine.cpu.internal_cycles);
}

test "ARM reads from unused memory take their lanes from the lookahead opcode" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0x91, 0xE5, // LDR r0, [r1]
        0x01, 0x20, 0xD1, 0xE5, // LDRB r2, [r1, #1]
        0x00, 0xFF, 0x2F, 0xE1, // First read sees this word.
        0x11, 0x22, 0x33, 0x44, // Second read sees byte lane 1 of this word.
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = 0x8000_0000;
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0xE12F_FF00), machine.cpu.readRegister(0));
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x22), machine.cpu.readRegister(2));
}

test "timed cartridge branch loop raises VBlank IF even with IRQ delivery masked" {
    const std = @import("std");
    const rom = [_]u8{
        0xFE, 0xFF, 0xFF, 0xEA, // B to self (20 cycles per iteration).
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    // Seed hardware state directly so inspection does not interrupt the Game Pak burst.
    machine.bus.dispstat |= 1 << 3;
    for (0..vblank_start / 20 - 1) |_| try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start - 20), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 9), machine.bus.dispstat);
    try std.testing.expectEqual(@as(u16, 1), machine.bus.irq_flags);
    try std.testing.expect(!machine.bus.irqLine());

    machine.bus.writeData(u16, Bus.if_address, 1);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
}

test "timed ROM fetches use WAITCNT even with prefetch enabled" {
    const std = @import("std");
    const rom = [_]u8{
        0xFE, 0xFF, 0xFF, 0xEA, // B to self.
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 20), machine.elapsed_cycles);

    machine.bus.writeData(u16, Bus.waitcnt_address, 0x0018);
    try machine.stepTimed();
    // The register write breaks the sequence, then the branch breaks it again.
    try std.testing.expectEqual(@as(u64, 20 + 5 + 5 + 4), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 34 + 4 + 5 + 4), machine.elapsed_cycles);

    machine.bus.writeData(u16, Bus.waitcnt_address, 0x4018);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 47 + 5 + 5 + 4), machine.elapsed_cycles);
}

test "timed IWRAM store charges one data cycle and breaks the next ROM fetch" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0x81, 0xE5, // STR r0, [r1]
        0x01, 0x20, 0xA0, 0xE3, // MOV r2, #1
        0x02, 0x20, 0xA0, 0xE3, // MOV r2, #2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = 42;
    machine.cpu.registers[1] = Bus.iwram_base;

    try machine.stepTimed();
    try std.testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, machine.bus.iwram[0..4]);
    try std.testing.expectEqual(@as(u64, 0), machine.cpu.internal_cycles);
    try std.testing.expectEqual(@as(u64, 6 + 1), machine.elapsed_cycles);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 7 + 8), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 15 + 6), machine.elapsed_cycles);
}

test "timed IWRAM load charges a data cycle and an internal cycle" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0x91, 0xE5, // LDR r0, [r1]
        0x01, 0x20, 0xA0, 0xE3, // MOV r2, #1
        0x02, 0x20, 0xA0, 0xE3, // MOV r2, #2
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.iwram_base;
    // Seed the bytes without issuing a bus transaction before the load.
    std.mem.writeInt(u32, machine.bus.iwram[0..4], 42, .little);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[0]);
    try std.testing.expectEqual(@as(u64, 1), machine.bus.iwram_data_cycles);
    try std.testing.expectEqual(@as(u64, 1), machine.cpu.internal_cycles);
    try std.testing.expectEqual(@as(u64, 6 + 1 + 1), machine.elapsed_cycles);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 8 + 8), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 16 + 6), machine.elapsed_cycles);
}

test "timed Game Pak data load pays the nonsequential data access cost" {
    const std = @import("std");
    const rom = [_]u8{ 0x00, 0x00, 0x91, 0xE5, 0, 0, 0, 0, 0, 0, 0, 0 }; // LDR r0, [r1]
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.rom_base;
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0xE591_0000), machine.cpu.registers[0]);
    try std.testing.expectEqual(@as(u64, 6 + 8 + 1), machine.elapsed_cycles);
}

test "a BIOS SWI can read its literal and leaves a protected fetch word after return" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x20, 0x91, 0xE5, // LDR r2, [r1], before any BIOS fetch.
        0x01, 0x00, 0x00, 0xEF, // SWI
        0x00, 0x30, 0x91, 0xE5, // LDR r3, [r1], after the SWI returns.
        0x00, 0x00, 0x00, 0x00,
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], 0x1122_3344, .little);
        std.mem.writeInt(u32, bytes[8..12], 0xE59F_0010, .little); // LDR r0, [pc, #16]
        std.mem.writeInt(u32, bytes[12..16], 0xE1B0_F00E, .little); // MOVS pc, lr
        std.mem.writeInt(u32, bytes[20..24], 0xE1A0_0000, .little); // Return instruction's lookahead.
        std.mem.writeInt(u32, bytes[32..36], 0x1234_5678, .little);
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, &bios);
    try std.testing.expectEqual(@as(u32, 0x0300_7F00), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0), machine.cpu.readRegister(2));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 8), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u32, 0x0300_7FE0), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0x1234_5678), machine.cpu.readRegister(0));
    try std.testing.expectEqual(@as(u32, 0), machine.bus.readData(u32, 0));
    try machine.step();
    try std.testing.expectEqual(Bus.rom_base + 8, machine.cpu.instruction_address);
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0xE1A0_0000), machine.cpu.readRegister(3));
}

test "cold boot executes BIOS reset code before the cartridge reads POSTFLG and the latch" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x20, 0xD1, 0xE5, // LDRB r2, [r1] (POSTFLG)
        0x00, 0x30, 0x94, 0xE5, // LDR r3, [r4] (protected BIOS)
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0..4], 0xE59F_100C, .little); // LDR r1, [pc, #12]
        std.mem.writeInt(u32, bytes[4..8], 0xE3A0_0001, .little); // MOV r0, #1
        std.mem.writeInt(u32, bytes[8..12], 0xE5C1_0000, .little); // STRB r0, [r1]
        std.mem.writeInt(u32, bytes[12..16], 0xE3A0_0302, .little); // MOV r0, #0x08000000
        std.mem.writeInt(u32, bytes[16..20], 0xE12F_FF10, .little); // BX r0
        std.mem.writeInt(u32, bytes[20..24], 0x0400_0300, .little);
        std.mem.writeInt(u32, bytes[24..28], 0xE1A0_0000, .little); // Last BIOS fetch.
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initBios(&rom, &bios);
    try std.testing.expectEqual(@as(u32, 0), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u8, 0), machine.bus.readData(u8, 0x0400_0300));
    for (0..5) |_| try machine.stepTimed();
    try std.testing.expectEqual(Bus.rom_base, machine.cpu.instruction_address);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 1), machine.cpu.readRegister(2));
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0xE1A0_0000), machine.cpu.readRegister(3));
}

test "BIOS HALT wakes on a cascaded timer interrupt with IME disabled" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0x00, 0xC1, 0xE5, // STRB r0, [r1] outside BIOS is ignored.
        0x02, 0x00, 0x00, 0xEF, // SWI
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[8..12], 0xE5C1_0000, .little); // STRB r0, [r1]
        std.mem.writeInt(u32, bytes[12..16], 0xE3A0_202A, .little); // MOV r2, #42
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, &bios);
    machine.cpu.registers[1] = Bus.haltcnt_address;

    try machine.stepTimed();
    try std.testing.expect(!machine.bus.halted);
    try machine.stepTimed();
    try machine.stepTimed();
    try std.testing.expect(machine.bus.halted);

    machine.bus.writeData(u16, Bus.ie_address, 1 << 4);
    machine.bus.requestInterrupt(1); // A pending VBlank cannot wake without IE.
    machine.bus.writeData(u32, 0x0400_0100, 0x0081_FFFF); // Timer 0 ticks every 64 cycles.
    machine.bus.writeData(u32, 0x0400_0104, 0x00C4_FFFE); // Timer 1 overflows on the second cascade tick.
    // Timer 0 samples the free-running divider at cycles 64 and 128.
    const bus_cycles = machine.bus.bus_cycles;

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 64), machine.elapsed_cycles);
    try std.testing.expect(!machine.bus.hasEnabledInterrupt());
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 128), machine.elapsed_cycles);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 129), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 0x11), machine.bus.irq_flags);
    try std.testing.expectEqual(bus_cycles, machine.bus.bus_cycles);
    try std.testing.expectEqual(@as(u32, 12), machine.cpu.instruction_address);

    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 130), machine.elapsed_cycles);
    try std.testing.expect(machine.bus.halted);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, 131), machine.elapsed_cycles);
    try std.testing.expect(!machine.bus.halted);
    try std.testing.expectEqual(bus_cycles, machine.bus.bus_cycles);
    try std.testing.expectEqual(@as(u32, 12), machine.cpu.instruction_address);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[2]);
    try std.testing.expectEqual(@as(u16, 0x11), machine.bus.irq_flags);
}

test "Machine takes a pending IRQ at a Thumb instruction boundary" {
    const std = @import("std");
    const rom = [_]u8{
        0x10, 0xFF, 0x2F, 0xE1, // BX r0
        0x2A, 0x21, 0x00, 0x00, // MOV r1, #42, then Thumb lookahead.
        0x00, 0x00, 0x00, 0x00, // ARM lookahead.
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[0x18..0x1C], 0xE1A0_0000, .little);
        std.mem.writeInt(u32, bytes[0x1C..0x20], 0xE1A0_1001, .little);
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = Bus.rom_base + 5;
    machine.bus.requestInterrupt(1);
    machine.bus.writeData(u16, Bus.ie_address, 1);
    machine.bus.writeData(u16, Bus.ime_address, 1);

    // The initial CPU IRQ mask lets BX execute despite the asserted line.
    try machine.step();
    try std.testing.expectEqual(Bus.rom_base + 4, machine.cpu.instruction_address);
    machine.cpu.cpsr &= ~@as(u32, 1 << 7);
    const interrupted_status = machine.cpu.cpsr;
    try std.testing.expectError(error.IrqNeedsBios, machine.step());
    try std.testing.expectEqual(interrupted_status, machine.cpu.cpsr);

    machine.bus.bios = &bios;
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0), machine.cpu.registers[1]);
    try std.testing.expectEqual(@as(u32, 0x18), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u32, 0xD2), machine.cpu.cpsr);
    try std.testing.expectEqual(interrupted_status, machine.cpu.spsr[3]);
    try std.testing.expectEqual(Bus.rom_base + 8, machine.cpu.banked.irq[1]);
    try std.testing.expectEqual([2]u32{ 0xE1A0_0000, 0xE1A0_1001 }, machine.cpu.pipeline.?);
    try std.testing.expect(machine.bus.irqLine());
}

pub fn snapshotMode3(self: *const Machine, frame: *video.Frame) error{NotMode3}!void {
    if (self.bus.dispcnt & 0b111 != 3) return error.NotMode3;
    video.decodeMode3(self.bus.vram[0..video.bitmap_size_bytes], frame);
}

/// Capture the current display configuration for instruction stepping and inspection.
pub fn snapshotBitmap(self: *const Machine, frame: *video.Frame) error{UnsupportedDisplayMode}!void {
    switch (self.bus.dispcnt & 7) {
        0 => {
            const display = self.mode0Display();
            for (frame, 0..) |*row, y| display.renderLine(y, row);
        },
        3 => video.decodeMode3(self.bus.vram[0..video.bitmap_size_bytes], frame),
        4 => self.snapshotMode4(frame),
        else => return error.UnsupportedDisplayMode,
    }
}

/// Return the completed Mode 0 scanlines when called at the end of runFrame.
pub fn snapshotFrame(self: *const Machine, frame: *video.Frame) error{UnsupportedDisplayMode}!void {
    if (self.mode0_frame_number == self.elapsed_cycles / timing.cycles_per_frame) {
        frame.* = self.mode0_frame;
        return;
    }
    try self.snapshotBitmap(frame);
}

fn mode0Display(self: *const Machine) mode0.Display {
    return .{
        .control = self.bus.dispcnt,
        .green_swap = self.bus.greenswap != 0,
        .registers = &self.bus.display_registers,
        .vram = &self.bus.vram,
        .palette = &self.bus.palette,
        .oam = &self.bus.oam,
    };
}

test "Mode 0 scrolls and flips 8bpp tiles across a four-block text map" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    const bus = &machine.bus;
    bus.writeData(u16, Bus.dispcnt_address, 0x0100);
    // BG0 uses a 512×512 map at block 4, with both scroll offsets at the wrap point.
    bus.writeData(u32, 0x0400_0008, 0xC480);
    bus.writeData(u32, 0x0400_0010, 0x01FF_01FF);
    bus.writeData(u16, Bus.vram_base + 0x3FFE, 0xFC01);
    bus.writeData(u16, Bus.vram_base + 0x37C0, 2);
    bus.writeData(u16, Bus.vram_base + 64, 1);
    bus.writeData(u16, Bus.vram_base + 128 + 7 * 8, 2);
    bus.writeData(u16, Bus.palette_base + 2, 0x03E0);
    bus.writeData(u16, Bus.palette_base + 4, 0x001F);

    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x03E0), frame[0][0]);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[0][1]);
    try std.testing.expectEqual(video.decodeColor(0), frame[1][0]);
    // A two-dot mosaic repeats the sample before the scroll coordinate wraps.
    bus.writeData(u16, 0x0400_0008, 0xC4C0);
    bus.writeData(u16, 0x0400_004C, 0x0011);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x03E0), frame[1][1]);
}

test "Mode 0 composites sprites through window masks, alpha and affine sampling" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    const bus = &machine.bus;
    bus.writeData(u16, Bus.dispcnt_address, 0xB100);
    bus.writeData(u16, 0x0400_0008, 0x0400);
    @memset(bus.vram[0..32], 0x11); // A solid red BG0 tile.
    @memset(bus.vram[0x10020..0x10040], 0x22); // A solid blue OBJ tile.
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 512 + 4, 0x7C00);
    bus.writeData(u32, Bus.oam_base, 0x0000_0400); // Semi-transparent OBJ at (0, 0).
    bus.writeData(u16, Bus.oam_base + 4, 1);
    bus.writeData(u32, Bus.oam_base + 8, 0x0008_0800); // OBJ window at (8, 0).
    bus.writeData(u16, Bus.oam_base + 12, 1);
    bus.writeData(u16, 0x0400_0040, 4);
    bus.writeData(u16, 0x0400_0044, 8);
    // Window 0 draws BG0 and OBJ with effects off. The OBJ window hides both.
    bus.writeData(u32, 0x0400_0048, 0x0031_0011);
    bus.writeData(u32, 0x0400_0050, 0x0808_0100);

    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x7C00), frame[0][3]);
    try std.testing.expectEqual(video.decodeColor(0x3C0F), frame[0][4]);
    try std.testing.expectEqual(video.decodeColor(0), frame[0][8]);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[0][16]);

    bus.writeData(u16, Bus.dispcnt_address, 0x1100);
    bus.writeData(u16, Bus.oam_base, 0x0300); // Double-size affine OBJ.
    bus.writeData(u16, Bus.oam_base + 6, 0x0100);
    bus.writeData(u16, Bus.oam_base + 30, 0x0100);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[3][4]);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[4][3]);
    try std.testing.expectEqual(video.decodeColor(0x7C00), frame[4][4]);
}

test "Mode 0 replay samples visible lines before HBlank DMA updates the backdrop" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0xFE, 0xFF, 0xFF, 0xEA }); // B to self.
    const bus = &machine.bus;
    bus.writeData(u32, Bus.iwram_base, 0x03E0_001F);
    bus.writeData(u32, 0x0400_00D4, Bus.iwram_base);
    bus.writeData(u32, 0x0400_00D8, Bus.palette_base);
    bus.writeData(u32, 0x0400_00DC, 0xA240_0001);
    try machine.runFrame(0);

    var frame: video.Frame = undefined;
    try machine.snapshotFrame(&frame);
    try std.testing.expectEqual(video.decodeColor(0), frame[0][0]);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[1][0]);
    try std.testing.expectEqual(video.decodeColor(0x03E0), frame[2][0]);
}

fn snapshotMode4(self: *const Machine, frame: *video.Frame) void {
    const registers = &self.bus.display_registers;
    const page = self.bus.dispcnt & (1 << 4) != 0;
    const offset: usize = if (page) video.mode4_page_stride_bytes else 0;
    const mosaic_enabled = registers.stored(0x0400_000C) & (1 << 6) != 0;
    const mosaic = registers.stored(0x0400_004C);
    video.renderMode4(
        self.bus.vram[offset..][0..video.mode4_bitmap_size_bytes],
        self.bus.palette[0..video.background_palette_size_bytes],
        .{
            .enabled = self.bus.dispcnt & (1 << 10) != 0,
            .forced_blank = self.bus.dispcnt & (1 << 7) != 0,
            .green_swap = self.bus.greenswap != 0,
            .dx = @bitCast(registers.stored(0x0400_0020)),
            .dmx = @bitCast(registers.stored(0x0400_0022)),
            .dy = @bitCast(registers.stored(0x0400_0024)),
            .dmy = @bitCast(registers.stored(0x0400_0026)),
            .origin_x = registers.affineReference(0x0400_0028),
            .origin_y = registers.affineReference(0x0400_002C),
            .mosaic_width = if (mosaic_enabled) 1 + @as(u5, @as(u4, @truncate(mosaic))) else 1,
            .mosaic_height = if (mosaic_enabled) 1 + @as(u5, @as(u4, @truncate(mosaic >> 4))) else 1,
        },
        frame,
    );
}

test "machine clock routes timer overflow IRQs while delivery is masked" {
    const std = @import("std");
    // Keep the CPU idle to isolate shared-clock device advancement and IRQ latching.
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    machine.bus.writeData(u32, 0x0400_0100, 0x00C0_FFFE);
    machine.advanceClock(3);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
    machine.advanceClock(1);
    try std.testing.expectEqual(@as(u16, 8), machine.bus.irq_flags);
    try std.testing.expect(!machine.bus.irqLine());
    try std.testing.expectEqual(@as(u16, 0xFFFF), machine.bus.readData(u16, 0x0400_0100));
}

test "a Thumb VCOUNT polling loop writes palette RAM once on each VBlank" {
    const std = @import("std");
    const rom = [_]u8{
        0x14, 0xFF, 0x2F, 0xE1, // BX r4
        0,    0,    0,    0,
        0,    0,    0,    0,
        0x08, 0x78, // wait_draw: LDRB r0, [r1]
        0xA0, 0x28, // CMP r0, #160
        0xFC, 0xD2, // BHS wait_draw
        0x08, 0x78, // wait_blank: LDRB r0, [r1]
        0xA0, 0x28, // CMP r0, #160
        0xFC, 0xD3, // BLO wait_blank
        0x01, 0x33, // ADDS r3, #1
        0x13, 0x80, // STRH r3, [r2]
        0xF6, 0xE7, // B wait_draw
        0,    0,
        0,    0,
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.vcount_address;
    machine.cpu.registers[2] = Bus.palette_base;
    machine.cpu.registers[4] = Bus.rom_base + 13;
    machine.bus.writeData(u16, Bus.waitcnt_address, 0x4317);

    for (0..3) |frame| {
        try machine.runToVBlank(timing.cycles_per_frame);
        try std.testing.expectEqual(@as(u8, 160), machine.bus.vcount);
        const edge = timing.vblank_start + frame * timing.cycles_per_frame;
        try std.testing.expect(machine.elapsed_cycles >= edge);
        try std.testing.expect(machine.elapsed_cycles < edge + 32);
        // Let the polling branch observe line 160 and execute its palette store.
        for (0..16) |_| try machine.stepTimed();
        const color = std.mem.readInt(u16, machine.bus.palette[0..2], .little);
        try std.testing.expectEqual(@as(u16, @intCast(frame + 1)), color);
    }
}

test "Mode 4 selects the front and back pages and uses the live background palette" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const bus = &machine.bus;
    // The default BG2 transform maps bitmap pixels directly to the screen.
    bus.writeData(u16, Bus.palette_base, 0x7C00);
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 510, 0x03E0);
    bus.writeData(u16, Bus.palette_base + 512, 0x7FFF);
    bus.writeData(u16, Bus.vram_base, 0x0001);
    bus.writeData(u16, Bus.vram_base + 0xA000, 0xFF00);
    bus.writeData(u16, Bus.vram_base + 0xA000 + 0x95FE, 0xFF00);

    const red: video.Rgb = .{ .red = 255, .green = 0, .blue = 0 };
    const green: video.Rgb = .{ .red = 0, .green = 255, .blue = 0 };
    const blue: video.Rgb = .{ .red = 0, .green = 0, .blue = 255 };
    const white: video.Rgb = .{ .red = 255, .green = 255, .blue = 255 };
    var frame: video.Frame = undefined;
    bus.writeData(u16, Bus.dispcnt_address, 1);
    try std.testing.expectError(error.UnsupportedDisplayMode, machine.snapshotBitmap(&frame));
    bus.writeData(u16, Bus.dispcnt_address, 0x0404);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(red, frame[0][0]);
    try std.testing.expectEqual(blue, frame[0][1]);
    bus.writeData(u8, Bus.dispcnt_address, 0x14);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(blue, frame[0][0]);
    try std.testing.expectEqual(green, frame[0][1]);
    try std.testing.expectEqual(green, frame[video.height - 1][video.width - 1]);
    bus.writeData(u16, Bus.palette_base + 510, 0x801F);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(red, frame[0][1]);
    bus.writeData(u16, Bus.palette_base + 510, 0x03E0);
    bus.writeData(u16, Bus.dispcnt_address + 2, 1);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 255, .blue = 255 }, frame[0][0]);
    try std.testing.expectEqual(video.Rgb{ .red = 0, .green = 0, .blue = 0 }, frame[0][1]);
    bus.writeData(u16, Bus.dispcnt_address + 2, 0);
    bus.writeData(u16, Bus.dispcnt_address, 0x0014);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(blue, frame[0][1]);
    bus.writeData(u16, Bus.dispcnt_address, 0x0494);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(white, frame[0][0]);
    try std.testing.expectEqual(white, frame[video.height - 1][video.width - 1]);
}

test "Mode 4 samples signed BG2 coordinates with mosaic and backdrop clipping" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const bus = &machine.bus;
    bus.writeData(u16, Bus.dispcnt_address, 0x0404);
    bus.writeData(u16, 0x0400_0020, 0x0100);
    bus.writeData(u16, 0x0400_0026, 0x0100);
    bus.writeData(u32, 0x0400_0028, 0x0FFF_FF00); // BG2X = -1.0.
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 4, 0x03E0);
    bus.writeData(u16, Bus.palette_base + 6, 0x7C00);
    bus.writeData(u16, Bus.vram_base, 0x0201);
    bus.writeData(u16, Bus.vram_base + video.width, 0x0303);

    const red: video.Rgb = .{ .red = 255, .green = 0, .blue = 0 };
    const green: video.Rgb = .{ .red = 0, .green = 255, .blue = 0 };
    const blue: video.Rgb = .{ .red = 0, .green = 0, .blue = 255 };
    const black: video.Rgb = .{ .red = 0, .green = 0, .blue = 0 };
    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(black, frame[0][0]);
    try std.testing.expectEqual(red, frame[0][1]);
    try std.testing.expectEqual(green, frame[0][2]);
    try std.testing.expectEqual(blue, frame[1][1]);

    bus.writeData(u16, 0x0400_000C, 1 << 6); // Enable BG2 mosaic.
    bus.writeData(u16, 0x0400_004C, 0x0011); // 2 x 2 mosaic blocks.
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(black, frame[0][1]);
    try std.testing.expectEqual(green, frame[0][2]);
    try std.testing.expectEqual(green, frame[1][3]);
}
