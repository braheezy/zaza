const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Audio = @import("audio.zig");
const Machine = @This();
const video = @import("video.zig");
const Display = @import("display.zig").Display;
const VerticalWindows = @import("display.zig").VerticalWindows;
const timing = @import("timing.zig");
const input = @import("input.zig");
const SaveMemory = @import("save_memory.zig");

cpu: Cpu,
bus: Bus,
elapsed_cycles: u64 = 0,
next_display_edge: u64 = timing.hblank_start,
dma_cycles_pending: u64 = 0,
rendered_frame: video.Frame = @splat(@splat(.{ .red = 0, .green = 0, .blue = 0 })),
vertical_windows: VerticalWindows = .{},
text_bg_latch: u16 = 0,
line_oam: [1024]u8 = @splat(0),
rendered_lines: usize = 0,
rendered_frame_number: ?u64 = null,

const vblank_start = timing.vblank_start;

/// In-process checkpoint taken between machine steps. All mutable state is
/// copied. The caller must keep the immutable ROM and BIOS images alive.
pub const Checkpoint = struct {
    state: Machine,

    pub fn restore(self: *const Checkpoint, destination: *Machine, capture: ?*Audio.Capture) void {
        destination.* = self.state;
        destination.bus.audio.capture = capture;
    }
};

pub fn checkpoint(self: *const Machine, destination: *Checkpoint) void {
    destination.state = self.*;
    destination.state.bus.audio.capture = null;
}

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
    const internal_cycles = try self.stepCpu();
    self.bus.cpu_internal_cycles += internal_cycles;
}

fn stepCpu(self: *Machine) !u64 {
    if (self.bus.halted) {
        if (!self.bus.hasEnabledInterrupt()) return 0;
        self.bus.halted = false;
    }
    // Sample IRQ before executing the next queued instruction.
    if (self.bus.irqLine() and !self.cpu.irqMasked()) {
        if (self.bus.bios == null) return error.IrqNeedsBios;
        self.bus.dma_bus_word = null;
        self.cpu.enterIrq(&self.bus);
        return 0;
    }
    // BIOS data visibility depends on the executing instruction, not lookahead fetches.
    self.bus.executing_bios = self.cpu.instruction_address < Bus.bios_size_bytes;
    const internal_before = self.cpu.internal_cycles;
    const result = self.cpu.step(&self.bus);
    self.bus.executing_bios = false;
    try result;
    self.bus.dma_bus_word = null;
    return self.cpu.internal_cycles - internal_before;
}

/// Advance the clock for one CPU instruction, IRQ entry, or halted interval.
/// Bus and internal cycles advance the shared device clock.
pub fn stepTimed(self: *Machine) !void {
    if (self.dma_cycles_pending != 0) {
        // A display-triggered DMA owns the bus before the CPU can step again.
        const cycles = self.dma_cycles_pending;
        self.dma_cycles_pending = 0;
        self.advanceClock(cycles);
        return;
    }
    if (self.bus.halted) {
        if (self.bus.immediate_dma_at) |ready| {
            const remaining = ready -| (self.bus.bus_cycles + self.bus.cpu_internal_cycles);
            if (remaining != 0) {
                self.bus.cpu_internal_cycles += remaining;
                self.advanceClock(remaining);
                return;
            }
            const before = self.bus.bus_cycles;
            self.bus.arbitrateDma();
            if (self.bus.bus_cycles != before) {
                self.advanceClock(self.bus.bus_cycles - before);
                return;
            }
        }
        if (self.bus.hasEnabledInterrupt()) {
            // Synchronization and CPU restart both leave the instruction pipeline idle.
            if (self.bus.haltWakeLine()) self.bus.halted = false;
            self.advanceClock(1);
            return;
        }
        const display_cycles = self.next_display_edge - self.elapsed_cycles;
        // Timer and display events can wake the CPU. Line boundaries also
        // let runToVBlank stop exactly at its target while the CPU sleeps.
        const timer_cycles = if (self.bus.peripheral_irq_pending != 0) 1 else self.bus.timers.cyclesUntilOverflow();
        self.advanceClock(@min(display_cycles, timer_cycles, self.bus.serial.cyclesUntilCompletion()));
        return;
    }
    self.advanceClock(try self.stepInstruction(false));
}

fn stepInstruction(self: *Machine, comptime batched_arm: bool) !u64 {
    const bus_cycles_before = self.bus.bus_cycles;
    self.bus.instruction_bus_origin = bus_cycles_before;
    defer self.bus.instruction_bus_origin = null;
    const internal_cycles = if (batched_arm) blk: {
        const before = self.cpu.internal_cycles;
        try self.cpu.stepArm(&self.bus);
        self.bus.dma_bus_word = null;
        break :blk self.cpu.internal_cycles - before;
    } else try self.stepCpu();
    self.bus.instruction_bus_origin = null;
    const bus_cycles = self.bus.bus_cycles - bus_cycles_before;
    self.finishInternalCycles(internal_cycles);
    return bus_cycles + internal_cycles;
}

inline fn finishInternalCycles(self: *Machine, cycles: u64) void {
    if (cycles == 0) return;
    self.bus.cpu_internal_cycles += cycles;
    self.bus.next_fetch_nonsequential = true;
    self.bus.cartridge_prefetch.advance(cycles);
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
    var remaining = instruction_budget;
    while (remaining != 0) {
        remaining -= try self.stepBatch(remaining);
        if (self.elapsed_cycles >= target) return;
    }
    return error.InstructionBudgetExceeded;
}

// Defer device updates only while every elapsed cycle precedes the first event.
fn stepBatch(self: *Machine, limit: usize) !usize {
    const bus = &self.bus;
    if (self.dma_cycles_pending != 0 or bus.halted or bus.immediate_dma_at != null or
        bus.pending_timer_write != null or bus.peripheral_irq_pending | bus.peripheral_irq_new | bus.peripheral_irq_sync != 0)
    {
        try self.stepTimed();
        return 1;
    }
    var interval = @min(self.next_display_edge - self.elapsed_cycles, bus.timers.cyclesUntilOverflow(), bus.serial.cyclesUntilCompletion());
    if (bus.audio.capture != null) interval = @min(interval, @as(u64, Audio.sample_period) - bus.audio.sample_phase);
    bus.batch_deadline = self.elapsed_cycles + interval;
    defer {
        bus.flushDeferred();
        bus.batch_deadline = 0;
    }
    // With no asserted IRQ, only a device deadline or a peripheral access can raise one.
    const region = self.cpu.instruction_address >> 24;
    if ((region == 0x03 or (region >= 0x08 and region <= 0x0D)) and self.cpu.inArmState() and !bus.irqLine())
        return if (region == 3) self.runBatch(limit, .iwram) else self.runBatch(limit, .rom);
    if (!self.cpu.inArmState() and region >= 0x08 and region <= 0x0D and !bus.irqLine())
        return self.runThumbBatch(limit, interval);
    return self.runBatch(limit, .generic);
}

// The read-only runner can skip repeated polling iterations. Its first unhandled
// instruction and the rest of this interval use the ordinary Thumb handlers.
fn runThumbBatch(self: *Machine, limit: usize, interval: u64) !usize {
    const bus = &self.bus;
    const prefix = self.cpu.runReadOnlyThumbUntil(bus, limit, interval);
    var count = prefix.instructions;
    var edge_cycles = prefix.edge_cycles;
    var elapsed = prefix.cycles - edge_cycles;
    bus.deferred_cycles = elapsed;

    // Peripheral accesses flush earlier instructions at the actual bus beat.
    // The instruction that reaches or changes a deadline advances devices separately.
    defer {
        bus.instruction_bus_origin = null;
        self.elapsed_cycles += elapsed;
        if (edge_cycles != 0) {
            bus.flushDeferred();
            self.advanceClock(edge_cycles);
        }
    }
    if (edge_cycles != 0) return count;
    while (count < limit) {
        const before = bus.bus_cycles;
        bus.instruction_bus_origin = before;
        const internal_before = self.cpu.internal_cycles;
        try self.cpu.stepQueuedThumb(bus);
        bus.dma_bus_word = null;
        const internal = self.cpu.internal_cycles - internal_before;
        self.finishInternalCycles(internal);

        count += 1;
        const cycles = bus.bus_cycles - before + internal;
        if (elapsed + cycles >= interval or bus.batch_deadline == 0) {
            edge_cycles = cycles;
            break;
        }
        elapsed += cycles;
        bus.deferred_cycles = elapsed;
        const region = self.cpu.instruction_address >> 24;
        if (region < 0x08 or region > 0x0D or self.cpu.inArmState()) break;
    }
    return count;
}

fn runBatch(self: *Machine, limit: usize, comptime mode: enum { generic, arm_dispatch, iwram, rom }) !usize {
    const bus = &self.bus;
    const region = self.cpu.instruction_address >> 24;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (mode == .iwram or mode == .rom) {
            const before_edge = bus.batch_deadline - self.elapsed_cycles;
            const run = if (mode == .iwram)
                self.cpu.runArmIwram(bus, limit - index, before_edge -| 1)
            else
                self.cpu.runRomAluSpan(bus, u32, limit - index, before_edge -| 1);
            // For mixed ROM code, amortize the next span probe across a device interval.
            if (mode == .rom and run.steps == 0) {
                return index + try self.runBatch(limit - index, .arm_dispatch);
            }
            self.elapsed_cycles += run.cycles;
            bus.deferred_cycles += run.cycles;
            index += run.steps;
            if (index == limit) return limit;
        }
        const cycles = try self.stepInstruction(mode != .generic);
        if (self.elapsed_cycles + cycles >= bus.batch_deadline) {
            bus.flushDeferred();
            self.advanceClock(cycles);
            return index + 1;
        }
        self.elapsed_cycles += cycles;
        bus.deferred_cycles += cycles;
        if (mode != .generic and (self.cpu.instruction_address >> 24 != region or !self.cpu.inArmState())) return index + 1;
    }
    return limit;
}

fn advanceClock(self: *Machine, cycles: u64) void {
    const end = self.elapsed_cycles + cycles;
    const before_dma = self.bus.bus_cycles;
    if (end < self.next_display_edge) {
        self.bus.advanceWithinDisplayInterval(cycles);
    } else {
        const old_phase = self.bus.display_phase;
        self.next_display_edge = self.renderVisibleLines(end);
        self.bus.advanceDevices(old_phase, cycles);
    }
    self.elapsed_cycles = end;
    self.dma_cycles_pending += self.bus.bus_cycles - before_dma;
}

fn renderVisibleLines(self: *Machine, end: u64) u64 {
    const line_phase = self.elapsed_cycles % timing.cycles_per_line;
    const next_hblank = timing.cyclesUntil(line_phase, timing.hblank_start, timing.cycles_per_line);
    var edge = self.elapsed_cycles + next_hblank;
    var line_start = self.elapsed_cycles + timing.cycles_per_line - line_phase;
    while (@min(line_start, edge) <= end) {
        if (line_start < edge) {
            const line: usize = @intCast((line_start % timing.cycles_per_frame) / timing.cycles_per_line);
            self.vertical_windows.beginLine(line, &self.bus.display_registers);
            line_start += timing.cycles_per_line;
        } else {
            self.renderAtHBlank(edge);
            edge += timing.cycles_per_line;
        }
    }
    return @min(line_start, edge);
}

fn renderAtHBlank(self: *Machine, edge: u64) void {
    const line: usize = @intCast((edge % timing.cycles_per_frame) / timing.cycles_per_line);
    const control = self.bus.scanlineDisplayControl();
    defer self.bus.bg_pixels_changed = false;
    // OBJ evaluation for the next line precedes OAM writes during HBlank.
    if (line == timing.lines_per_frame - 1) self.line_oam = self.bus.oam;
    if (line >= video.height) return;
    defer self.line_oam = self.bus.oam;
    if (line == 0) self.rendered_lines = 0;
    if (!self.supportsDisplayMode() or self.rendered_lines != line) return;

    // Sample the visible line before the bus applies HBlank DMA writes.
    var display = self.currentDisplay();
    display.control = control;
    if (self.bus.bg_pixels_changed) display.bg_pixel_mask = &self.bus.bg_pixel_mask;
    display.oam = &self.line_oam;
    display.renderLine(@intCast(line), &self.rendered_frame[line], &self.text_bg_latch);
    self.rendered_lines += 1;
    if (self.rendered_lines == video.height) {
        self.rendered_frame_number = edge / timing.cycles_per_frame;
    }
}

test "MSR can leave and reenter a register bank without losing its contents" {
    const std = @import("std");
    const rom = [_]u8{
        0x00, 0xF0, 0x21, 0xE1, // MSR CPSR_c, r0 (reserved mode)
        0x07, 0xD0, 0xA0, 0xE3, // MOV sp, #7
        0x0D, 0x20, 0xA0, 0xE1, // MOV r2, sp
        0x01, 0xF0, 0x21, 0xE1, // MSR CPSR_c, r1 (back to Supervisor)
    };
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[0] = 0x04;
    machine.cpu.registers[1] = 0x13;
    machine.cpu.banked.supervisor[0] = 0x0300_7FE0;
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x14), machine.cpu.cpsr);
    for (0..3) |_| try machine.stepTimed();
    try std.testing.expectEqual(@as(u32, 0), machine.cpu.readRegister(2));
    try std.testing.expectEqual(@as(u32, 0x13), machine.cpu.cpsr);
    try std.testing.expectEqual(@as(u32, 0x0300_7FE0), machine.cpu.readRegister(13));
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

test "an uninterrupted CPU batch stops at the first display edge" {
    const std = @import("std");
    const rom = [_]u8{ 0xFE, 0xFF, 0xFF, 0xEA }; // B to self.
    var batched: Machine = undefined;
    batched.initCartridge(&rom);
    var reference = batched;
    const edge = reference.next_display_edge;
    var steps: usize = 0;
    while (reference.elapsed_cycles < edge) : (steps += 1) try reference.stepTimed();
    try std.testing.expect(steps > 16);
    try std.testing.expectEqual(steps, try batched.stepBatch(timing.cycles_per_line));
    try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
    try std.testing.expectEqual(reference.bus.display_phase, batched.bus.display_phase);
    try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
}

test "IWRAM ARM batch observes an IRQ enabled by a guest store" {
    const std = @import("std");
    const bios: [Bus.bios_size_bytes]u8 = @splat(0);
    var batched: Machine = undefined;
    batched.initCartridgeWithBios(&.{}, &bios);
    batched.bus.writeData(u32, Bus.iwram_base, 0xE3A0_0001); // MOV r0, #1
    batched.bus.writeData(u32, Bus.iwram_base + 4, 0xE1C1_00B0); // STRH r0, [r1]
    batched.bus.writeData(u32, Bus.iwram_base + 8, 0xE3A0_202A); // MOV r2, #42
    batched.cpu.registers[1] = Bus.ime_address;
    batched.cpu.instruction_address = Bus.iwram_base;
    batched.cpu.refillArmPipeline(&batched.bus);
    batched.bus.irq_enable = 1;
    batched.bus.requestInterrupt(1);
    var reference = batched;
    try std.testing.expectEqual(@as(usize, 2), try batched.stepBatch(8));
    _ = try batched.stepBatch(1);
    for (0..3) |_| try reference.stepTimed();
    try std.testing.expectEqual(@as(u32, 0x18), batched.cpu.instruction_address);
    try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
    try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
    try std.testing.expectEqual(reference.bus.bus_cycles, batched.bus.bus_cycles);
}

test "IWRAM ARM batch stops after switching to Thumb" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    machine.bus.writeData(u32, Bus.iwram_base, 0xE12F_FF10); // BX r0
    machine.bus.writeData(u16, Bus.iwram_base + 8, 0x212A); // MOV r1, #42
    machine.cpu.registers[0] = Bus.iwram_base + 9;
    machine.cpu.instruction_address = Bus.iwram_base;
    machine.cpu.refillArmPipeline(&machine.bus);
    try std.testing.expectEqual(@as(usize, 1), try machine.stepBatch(8));
    _ = try machine.stepBatch(1);
    try std.testing.expectEqual(@as(u32, 42), machine.cpu.registers[1]);
}

test "Thumb polling observes HBlank DMA at the same instruction as single stepping" {
    const std = @import("std");
    const rom = [_]u8{
        0x08, 0x68, // LDR r0, [r1]
        0x00, 0x28, // CMP r0, #0
        0xFC, 0xD0, // BEQ to LDR
        0x2A, 0x24, // MOV r4, #42
        0xFE, 0xE7, // B to self
    };
    for ([_]u16{ 0, 0x4317 }) |waitcnt| {
        var batched: Machine = undefined;
        batched.initCartridge(&rom);
        const bus = &batched.bus;
        bus.writeData(u16, Bus.waitcnt_address, waitcnt);
        bus.writeData(u32, Bus.iwram_base, 1);
        bus.writeData(u32, 0x0400_00D4, Bus.iwram_base);
        bus.writeData(u32, 0x0400_00D8, Bus.ewram_base);
        bus.writeData(u32, 0x0400_00DC, 0xA400_0001);
        batched.cpu.registers[1] = Bus.ewram_base;
        const pc = Bus.rom_base + 0x0200_0000;
        batched.cpu.cpsr |= 1 << 5;
        batched.cpu.instruction_address = pc;
        batched.cpu.pipeline = .{ bus.fetch16(pc, .nonsequential), bus.fetch16(pc + 2, .sequential) };
        var reference = batched;
        for (0..64) |i| {
            const limit = [_]usize{ 1, 4, 17, 200 };
            const count = try batched.stepBatch(limit[i % limit.len]);
            try std.testing.expect(count > 0 and count <= limit[i % limit.len]);
            for (0..count) |_| try reference.stepTimed();
            try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
            try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
            try std.testing.expectEqual(reference.dma_cycles_pending, batched.dma_cycles_pending);
            try std.testing.expectEqualDeep(reference.bus, batched.bus);
            if (batched.cpu.registers[4] == 42) break;
        } else return error.DmaNotObserved;
    }
}

test "Thumb display polling samples the correct bus beat across display edges" {
    const std = @import("std");
    const rom = [_]u8{
        0x08, 0x88, // LDRH r0, [r1]
        0x10, 0x42, // TST r0, r2
        0xFC, 0xD0, // BEQ to LDRH
        0x2A, 0x24, // MOV r4, #42
        0xFE, 0xE7, // B to self
    };
    const cases = [_]struct { address: u32, mask: u32, edge: u64 }{
        .{ .address = Bus.dispstat_address, .mask = 2, .edge = timing.hblank_start },
        .{ .address = Bus.vcount_address, .mask = 1, .edge = timing.cycles_per_line },
        .{ .address = Bus.dispstat_address, .mask = 1, .edge = timing.vblank_start },
    };
    for (cases) |case| {
        for ([_]u64{ 2, 11, 13, 200 }) |distance| {
            var batched: Machine = undefined;
            batched.initCartridge(&rom);
            batched.elapsed_cycles = case.edge - distance;
            batched.bus.display_phase = batched.elapsed_cycles;
            batched.next_display_edge = case.edge;
            batched.cpu.registers[1] = case.address;
            batched.cpu.registers[2] = case.mask;
            const pc = Bus.rom_base + 0x0200_0000;
            batched.cpu.cpsr |= 1 << 5;
            batched.cpu.instruction_address = pc;
            batched.cpu.pipeline = .{ batched.bus.fetch16(pc, .nonsequential), batched.bus.fetch16(pc + 2, .sequential) };
            var reference = batched;
            for (0..32) |_| {
                const count = try batched.stepBatch(30);
                for (0..count) |_| try reference.stepTimed();
                try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
                try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
                try std.testing.expectEqualDeep(reference.bus, batched.bus);
                if (batched.cpu.registers[4] == 42) break;
            } else return error.DisplayEdgeNotObserved;
        }
    }
}

test "mixed Thumb run stops at MMIO and an exchange to ARM" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x24, // MOVS r4, #1
        0x08, 0x60, // STR r0, [r1]
        0x0A, 0x68, // LDR r2, [r1]
        0x90, 0x42, // CMP r0, r2
        0x00, 0xD0, // BEQ to STRH
        0xFF, 0x22, // MOVS r2, #255 (skipped)
        0x1A, 0x80, // STRH r2, [r3] (IME)
        0x28, 0x47, // BX r5
    };
    var batched: Machine = undefined;
    batched.initCartridge(&rom);
    batched.bus.writeData(u16, Bus.waitcnt_address, 0x4317);
    batched.cpu.registers[0] = 1;
    batched.cpu.registers[1] = Bus.ewram_base;
    batched.cpu.registers[3] = Bus.ime_address;
    batched.cpu.registers[5] = Bus.iwram_base;
    const pc = Bus.rom_base + 0x0200_0000;
    batched.cpu.cpsr |= 1 << 5;
    batched.cpu.instruction_address = pc;
    batched.cpu.pipeline = .{ batched.bus.fetch16(pc, .nonsequential), batched.bus.fetch16(pc + 2, .sequential) };
    var reference = batched;
    for ([_]usize{ 6, 1 }) |expected| {
        try std.testing.expectEqual(expected, try batched.stepBatch(32));
        for (0..expected) |_| try reference.stepTimed();
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqualDeep(reference.bus, batched.bus);
        try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
    }
    try std.testing.expect(batched.bus.ime_enabled);
    try std.testing.expect(batched.cpu.inArmState());
    try std.testing.expectEqual(Bus.iwram_base, batched.cpu.instruction_address);
}

test "Thumb decode fault preserves timing of earlier instructions in the batch" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x20, // MOVS r0, #1
        0x08, 0x60, // STR r0, [r1]
        0x00, 0xB1, // Unsupported on ARM7TDMI
        0x00, 0x00,
    };
    var batched: Machine = undefined;
    batched.initCartridge(&rom);
    batched.cpu.registers[1] = Bus.ewram_base;
    const pc = Bus.rom_base + 0x0200_0000;
    batched.cpu.cpsr |= 1 << 5;
    batched.cpu.instruction_address = pc;
    batched.cpu.pipeline = .{ batched.bus.fetch16(pc, .nonsequential), batched.bus.fetch16(pc + 2, .sequential) };
    var reference = batched;
    try reference.stepTimed();
    try reference.stepTimed();
    try std.testing.expectError(error.UnsupportedInstruction, reference.stepTimed());
    try std.testing.expectError(error.UnsupportedInstruction, batched.stepBatch(16));
    try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
    try std.testing.expectEqualDeep(reference.bus, batched.bus);
    try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
}

test "Thumb arithmetic spans hand off to timed MMIO without losing the pipeline" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x30, // ADDS r0, #1
        0x41, 0x00, // LSLS r1, r0, #1
        0x01, 0x39, // SUBS r1, #1
        0x01, 0x29, // CMP r1, #1
        0x13, 0x88, // LDRH r3, [r2] (running timer)
        0xF9, 0xE7, // B to ADDS
    };
    for ([_]u16{ 0, 0x4317 }) |waitcnt| {
        var batched: Machine = undefined;
        batched.initCartridge(&rom);
        batched.bus.writeData(u16, Bus.waitcnt_address, waitcnt);
        batched.cpu.registers[2] = 0x0400_0100;
        batched.bus.writeData(u32, 0x0400_0100, 0x00C0_FFC0);
        const pc = Bus.rom_base + 0x0200_0000;
        batched.cpu.cpsr |= 1 << 5;
        batched.cpu.instruction_address = pc;
        batched.cpu.pipeline = .{ batched.bus.fetch16(pc, .nonsequential), batched.bus.fetch16(pc + 2, .sequential) };
        var reference = batched;
        for (0..64) |_| {
            const count = try batched.stepBatch(19);
            for (0..count) |_| try reference.stepTimed();
            try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
            try std.testing.expectEqualDeep(reference.bus, batched.bus);
            try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
        }
    }
}

test "ARM spans preserve Game Pak wait states, FIFO and unbacked fetches at a page edge" {
    const std = @import("std");
    const rom = comptime blk: {
        var bytes = [_]u8{0} ** 0x20012;
        for (0..12) |i| std.mem.writeInt(u32, bytes[0x1FFE0 + i * 4 ..][0..4], 0xE280_0001, .little);
        break :blk bytes;
    };
    for ([_]u16{ 0, 0x4317 }) |waitcnt| {
        var batched: Machine = undefined;
        batched.initCartridge(&rom);
        batched.bus.writeData(u16, Bus.waitcnt_address, waitcnt);
        batched.cpu.instruction_address = Bus.rom_base + 0x1FFE0;
        batched.cpu.refillArmPipeline(&batched.bus);
        batched.bus.cartridge_prefetch.advance(4);
        var reference = batched;
        for ([_]usize{ 1, 3, 2, 5, 2 }) |limit| {
            const steps = try batched.stepBatch(limit);
            for (0..steps) |_| try reference.stepTimed();
            try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
            try std.testing.expectEqualDeep(reference.bus, batched.bus);
            try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
        }
    }
}

test "IWRAM arithmetic run preserves prefetched words, PC operands and bus timing" {
    const std = @import("std");
    var batched: Machine = undefined;
    batched.initCartridge(&.{});
    const words = [_]u32{
        0xE28F_0000, // ADD r0, pc, #0
        0xE250_1001, // SUBS r1, r0, #1
        0x0280_2001, // ADDEQ r2, r0, #1 (condition fails)
        0xE1A0_3311, // MOV r3, r1, LSL r3 (extra internal cycle)
        0xEAFF_FFFA, // B to ADD
    };
    for (words, 0..) |word, i| batched.bus.writeData(u32, Bus.iwram_base + @as(u32, @intCast(i * 4)), word);
    batched.cpu.instruction_address = Bus.iwram_base;
    batched.cpu.refillArmPipeline(&batched.bus);
    // An already prefetched opcode survives a write to its backing RAM.
    batched.bus.writeData(u32, Bus.iwram_base, 0xE3A0_002A);
    var reference = batched;
    for ([_]usize{ 1, 3, 5, 53, 1024 }) |limit| {
        const count = try batched.stepBatch(limit);
        for (0..count) |_| try reference.stepTimed();
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
        try std.testing.expectEqualDeep(reference.bus, batched.bus);
    }
}

test "mixed ARM work RAM runs preserve stores to code, load timing and branch refills" {
    const std = @import("std");
    var batched: Machine = undefined;
    batched.initCartridge(&.{});
    const code = Bus.iwram_base;
    const words = [_]u32{
        0xE582_3008, // STR r3, [r2, #8] overwrites the word fetched by this instruction.
        0xE5C1_3001, // STRB r3, [r1, #1]
        0xE280_0001, // ADD r0, r0, #1 (already queued on the first pass)
        0xE491_4004, // LDR r4, [r1], #4 (unaligned)
        0xE754_5004, // LDRB r5, [r4, -r4] (BIOS fallback)
        0xE251_1004, // SUBS r1, r1, #4
        0x05C1_3000, // STRBEQ r3, [r1] (condition fails)
        0x1BFF_FFF7, // BLNE to the first store
    };
    for (words, 0..) |word, i| {
        batched.bus.writeData(u32, code + @as(u32, @intCast(i * 4)), word);
    }
    batched.cpu.instruction_address = code;
    batched.cpu.refillArmPipeline(&batched.bus);
    batched.cpu.registers[1] = Bus.ewram_base + 1;
    batched.cpu.registers[2] = code;
    batched.cpu.registers[3] = 0xE280_0002; // ADD r0, r0, #2
    var reference = batched;
    for ([_]usize{ 3, 1, 8, 4, 17, 45, 900, 900, 900 }) |limit| {
        const count = try batched.stepBatch(limit);
        for (0..count) |_| try reference.stepTimed();
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqualDeep(reference.bus, batched.bus);
        try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
    }
}

test "batched ARM halfword and signed transfers match timed steps in both work RAM regions" {
    const std = @import("std");
    const words = [_]u32{
        0xE1E1_00B1, // STRH r0, [r1, #1]! (odd store aligns down)
        0xE1D1_20B0, // LDRH r2, [r1]
        0xE1D1_30F0, // LDRSH r3, [r1]
        0xE111_40D5, // LDRSB r4, [r1, -r5]
        0xE151_60F1, // LDRSH r6, [r1, #-1]
        0xE0D1_10B2, // LDRH r1, [r1], #2 (loaded value wins over writeback)
    };
    for ([_]u32{ Bus.ewram_base, Bus.iwram_base }) |region| {
        var batched: Machine = undefined;
        batched.initCartridge(&.{});
        for (words, 0..) |word, i| {
            batched.bus.writeData(u32, Bus.iwram_base + @as(u32, @intCast(i * 4)), word);
        }
        batched.cpu.instruction_address = Bus.iwram_base;
        batched.cpu.refillArmPipeline(&batched.bus);
        batched.cpu.registers[0] = 0x1234_80AB;
        batched.cpu.registers[1] = region + 0x100;
        batched.cpu.registers[5] = 1;
        var reference = batched;

        // One cycle is enough to fetch, but the store must wait for its data access.
        const short = batched.cpu.runArmIwram(&batched.bus, words.len, 1);
        try std.testing.expectEqual(@as(usize, 0), short.steps);
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqualDeep(reference.bus, batched.bus);

        // Finish exactly on the cycle budget with all six instructions in the runner.
        const data_cycles = timing.ramAccessCycles(u16, @truncate(region >> 24));
        const budget = words.len * (1 + @as(u64, data_cycles)) + 5;
        const run = batched.cpu.runArmIwram(&batched.bus, words.len, budget);
        try std.testing.expectEqual(words.len, run.steps);
        try std.testing.expectEqual(budget, run.cycles);
        batched = reference;

        try std.testing.expectEqual(words.len, try batched.stepBatch(words.len));
        for (words) |_| try reference.stepTimed();
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqualDeep(reference.bus, batched.bus);
        try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
        try std.testing.expectEqual(@as(u32, 0xAB00_0080), batched.cpu.registers[1]);
        try std.testing.expectEqual(@as(u32, 0xAB00_0080), batched.cpu.registers[2]);
        try std.testing.expectEqual(@as(u32, 0xFFFF_FF80), batched.cpu.registers[3]);
        try std.testing.expectEqual(@as(u32, 0xFFFF_FFAB), batched.cpu.registers[4]);
        try std.testing.expectEqual(@as(u32, 0xFFFF_80AB), batched.cpu.registers[6]);
    }
}

test "batched timer reads and IRQ propagation agree with individual timed steps" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x20, 0x82, 0xE2, // ADD r2, r2, #1
        0x01, 0x20, 0x82, 0xE2, // ADD r2, r2, #1
        0xB0, 0x00, 0xD1, 0xE1, // LDRH r0, [r1] (timer counter)
        0xFB, 0xFF, 0xFF, 0xEA, // B to first ADD
    };
    var batched: Machine = undefined;
    batched.initCartridge(&rom);
    batched.cpu.registers[1] = 0x0400_0100;
    batched.bus.writeData(u32, 0x0400_0100, 0x00C0_FF83);
    var reference = batched;
    var longest: usize = 0;
    while (batched.elapsed_cycles < timing.cycles_per_line * 2) {
        const count = try batched.stepBatch(16);
        longest = @max(longest, count);
        for (0..count) |_| try reference.stepTimed();
        try std.testing.expectEqualDeep(reference.cpu, batched.cpu);
        try std.testing.expectEqual(reference.elapsed_cycles, batched.elapsed_cycles);
        try std.testing.expectEqual(reference.bus.display_phase, batched.bus.display_phase);
        try std.testing.expectEqualDeep(reference.bus.timers, batched.bus.timers);
        try std.testing.expectEqual(reference.bus.irq_flags, batched.bus.irq_flags);
        try std.testing.expectEqual(reference.bus.peripheral_irq_pending, batched.bus.peripheral_irq_pending);
        try std.testing.expectEqual(reference.bus.peripheral_irq_new, batched.bus.peripheral_irq_new);
        try std.testing.expectEqual(reference.bus.peripheral_irq_sync, batched.bus.peripheral_irq_sync);
    }
    try std.testing.expect(longest > 1);
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
    // The cartridge batch must stop at SWI so the BIOS can read its own literal.
    var batched = machine;
    try std.testing.expectEqual(@as(usize, 2), try batched.stepBatch(8));
    _ = try batched.stepBatch(1);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), batched.cpu.readRegister(0));

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
    if (!self.supportsDisplayMode()) return error.UnsupportedDisplayMode;
    var display = self.currentDisplay();
    var latch = self.text_bg_latch;
    // For a static snapshot, settle the current limits through a complete VCOUNT cycle.
    for (0..timing.lines_per_frame) |line| display.vertical_windows.beginLine(line, display.registers);
    for (frame, 0..) |*row, y| {
        display.vertical_windows.beginLine(y, display.registers);
        display.renderLine(y, row, &latch);
    }
}

fn supportsDisplayMode(self: *const Machine) bool {
    return switch (self.bus.dispcnt & 7) {
        0...5 => true,
        else => false,
    };
}

/// Return the completed scanlines when called at the end of runFrame.
pub fn snapshotFrame(self: *const Machine, frame: *video.Frame) error{UnsupportedDisplayMode}!void {
    if (self.rendered_frame_number == self.elapsed_cycles / timing.cycles_per_frame) {
        frame.* = self.rendered_frame;
        return;
    }
    try self.snapshotBitmap(frame);
}

fn currentDisplay(self: *const Machine) Display {
    return .{
        .control = self.bus.dispcnt,
        .vertical_windows = self.vertical_windows,
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
    // A semitransparent OBJ still blends with BG0 when all windows are disabled.
    var row: [video.width]video.Rgb = undefined;
    machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
    try std.testing.expectEqual(video.decodeColor(0x3C0F), row[0]);
    bus.writeData(u16, Bus.oam_base, 0x0300); // Double-size affine OBJ.
    bus.writeData(u16, Bus.oam_base + 6, 0x0100);
    bus.writeData(u16, Bus.oam_base + 30, 0x0100);
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[3][4]);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[4][3]);
    try std.testing.expectEqual(video.decodeColor(0x7C00), frame[4][4]);
}

test "frontmost pixel composition matches a fully visible window in every mode" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    const bus = &machine.bus;
    var random = std.Random.DefaultPrng.init(73);
    random.random().bytes(&bus.vram);
    random.random().bytes(&bus.palette);
    // Select every layer and effects outside WIN0. Its vertical range stays inactive.
    bus.writeData(u16, 0x0400_004A, 0x003F);
    bus.writeData(u16, 0x0400_004C, 0x0023);
    bus.writeData(u16, 0x0400_0050, 0x003F);
    for (0..4) |bg| bus.writeData(u16, 0x0400_0008 + @as(u32, @intCast(bg * 2)), @intCast(0xC0 | (3 - bg)));
    for (0..6) |mode| {
        bus.writeData(u16, Bus.dispcnt_address, @intCast(0x1F00 | mode));
        var plain = machine.currentDisplay();
        plain.green_swap = true;
        var windowed = plain;
        windowed.control |= 1 << 13;
        var plain_latch: u16 = 0;
        var windowed_latch: u16 = 0;
        for ([_]usize{ 0, 5, 47, 159 }) |y| {
            var actual: [video.width]video.Rgb = undefined;
            var expected: [video.width]video.Rgb = undefined;
            plain.renderLine(y, &actual, &plain_latch);
            windowed.renderLine(y, &expected, &windowed_latch);
            try std.testing.expectEqualSlices(video.Rgb, &expected, &actual);
            try std.testing.expectEqual(windowed_latch, plain_latch);
        }
    }
}

test "bitmap BG2 priority and transparency compose with upper OBJ VRAM" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    const bus = &machine.bus;
    bus.writeData(u16, Bus.palette_base + 0x202, 0x7C00);
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.vram_base + 0x14000, 0x1111);
    bus.writeData(u16, Bus.oam_base + 4, 0x600); // Tile 512, priority 1.
    var row: [video.width]video.Rgb = undefined;
    for ([_]u16{ 3, 4, 5 }) |mode| {
        bus.writeData(u16, Bus.dispcnt_address, 0x1400 | mode);
        bus.writeData(u16, Bus.vram_base, if (mode == 4) 1 else 0x001F);
        bus.writeData(u16, 0x0400_000C, 0);
        machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
        try std.testing.expectEqual(video.decodeColor(0x001F), row[0]);
        try std.testing.expectEqual(video.decodeColor(if (mode == 4) 0x7C00 else 0), row[1]);
        bus.writeData(u16, 0x0400_000C, 1);
        machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
        try std.testing.expectEqual(video.decodeColor(0x7C00), row[0]);
    }
    // Lower OBJ tiles overlap the bitmap pages and cannot supply sprite pixels.
    bus.writeData(u16, Bus.oam_base + 4, 0);
    bus.writeData(u16, Bus.vram_base + 0x10000, 0x1111);
    machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
    try std.testing.expectEqual(video.decodeColor(0x001F), row[0]);
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
    bus.writeData(u16, Bus.dispcnt_address, 6);
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

test "Mode 2 composes two affine tilemaps with signed coordinates, scaling and overflow" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    const bus = &machine.bus;
    bus.writeData(u16, Bus.dispcnt_address, 0x0C02);
    bus.writeData(u16, 0x0400_000C, 0x0400); // BG2 map at 0x2000.
    bus.writeData(u16, 0x0400_000E, 0x0500); // BG3 map at 0x2800.
    bus.writeData(u16, 0x0400_0020, 0x0200); // Sample every second BG2 texel.
    bus.writeData(u32, 0x0400_0028, 0x0FFF_FF00); // BG2 starts at x = -1.
    bus.writeData(u16, Bus.palette_base + 2, 0x001F);
    bus.writeData(u16, Bus.palette_base + 4, 0x03E0);
    bus.vram[0x2000] = 1;
    bus.vram[0x200F] = 1;
    bus.vram[0x2800] = 2;
    bus.vram[64 + 1] = 1;
    bus.vram[64 + 7] = 1;
    @memset(bus.vram[128..136], 2);

    var frame: video.Frame = undefined;
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x03E0), frame[0][0]); // BG2 clips.
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[0][1]); // BG2 wins the tie.
    try std.testing.expectEqual(video.decodeColor(0x03E0), frame[0][2]); // Transparent texel.
    bus.writeData(u16, 0x0400_000C, 0x2400); // Wrap x = -1 to 127.
    try machine.snapshotBitmap(&frame);
    try std.testing.expectEqual(video.decodeColor(0x001F), frame[0][0]);
}

test "Mode 0 shares open bus between text layers and across invalid map reads" {
    const std = @import("std");
    var machine: Machine = undefined;
    machine.initCartridge(&.{});
    const bus = &machine.bus;
    var row: [video.width]video.Rgb = undefined;
    bus.writeData(u16, Bus.palette_base + 6, 0x001F);
    bus.writeData(u16, Bus.dispcnt_address, 0x0300);
    bus.writeData(u16, 0x0400_0008, 0x010C); // BG0 tile 512 exceeds character block 3.
    bus.writeData(u16, 0x0400_000A, 0x0200);
    bus.writeData(u16, Bus.vram_base + 0x800, 512);
    bus.writeData(u16, Bus.vram_base + 0x1000, 3);
    machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
    try std.testing.expectEqual(video.decodeColor(0x001F), row[0]);

    // Start in the right half of a wide map beginning at screen block 31.
    // The retained value selects tile 1. Both VRAM[0] and OBJ VRAM contain zero.
    bus.writeData(u16, Bus.dispcnt_address, 0x0100);
    bus.writeData(u16, 0x0400_0008, 0x5F00);
    bus.writeData(u16, 0x0400_0010, 256);
    bus.writeData(u16, Bus.vram_base + 32, 3);
    machine.text_bg_latch = 1;
    machine.currentDisplay().renderLine(0, &row, &machine.text_bg_latch);
    try std.testing.expectEqual(video.decodeColor(0x001F), row[0]);
}
