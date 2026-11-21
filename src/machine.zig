const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();
const video = @import("video.zig");

cpu: Cpu,
bus: Bus,
elapsed_cycles: u64 = 0,

const cycles_per_line = 1232;
const cycles_per_frame = cycles_per_line * 228;
const vblank_start = cycles_per_line * 160;
const vblank_end = cycles_per_line * 227;

// Start directly at the cartridge entry point without running the BIOS.
pub fn initCartridge(self: *Machine, rom: []const u8) void {
    self.* = .{
        .cpu = .{ .instruction_address = Bus.rom_base },
        .bus = .{ .rom = rom },
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
}

pub fn step(self: *Machine) !void {
    // Sample IRQ before executing the next queued instruction.
    if (self.bus.irqLine() and !self.cpu.irqMasked()) {
        if (self.bus.bios == null) return error.IrqNeedsBios;
        self.cpu.enterIrq(&self.bus);
        return;
    }
    // BIOS data visibility depends on the executing instruction, not lookahead fetches.
    self.bus.executing_bios = self.cpu.instruction_address < Bus.bios_size_bytes;
    defer self.bus.executing_bios = false;
    try self.cpu.step(&self.bus);
}

// Use this from cartridge startup; ordinary step() does not advance the clock.
pub fn stepTimed(self: *Machine) !void {
    if (self.bus.prefetchEnabled()) return error.UntimedPrefetch;
    if (self.bus.irqLine() and !self.cpu.irqMasked()) return error.UntimedIrq;
    const instruction = (self.cpu.pipeline orelse return error.PipelineNotReady)[0];
    const address = self.cpu.instruction_address;
    if (self.cpu.cpsr & (1 << 5) != 0) return error.UntimedInstruction;
    if (!self.romContainsWord(address) or !self.romContainsWord(address +% 8)) {
        return error.UntimedInstruction;
    }

    // Only admit instructions whose complete cost is tracked below.
    const mov_immediate = instruction & 0xFFF0_0000 == 0xE3A0_0000 and
        instruction >> 12 & 0xF != 0xF;
    if (instruction >> 24 == 0xEA) {
        const words: i24 = @bitCast(@as(u24, @truncate(instruction)));
        const target = address +% 8 +% @as(u32, @bitCast(@as(i32, words) * 4));
        if (!self.romContainsWord(target) or !self.romContainsWord(target +% 4)) {
            return error.UntimedInstruction;
        }
    } else if (!mov_immediate and !self.isTimedIwramTransfer(instruction)) {
        return error.UntimedInstruction;
    }

    const fetch_cycles_before = self.bus.rom_fetch_cycles;
    const data_cycles_before = self.bus.iwram_data_cycles;
    const internal_cycles_before = self.cpu.internal_cycles;
    try self.step();
    const fetch_cycles = self.bus.rom_fetch_cycles - fetch_cycles_before;
    const data_cycles = self.bus.iwram_data_cycles - data_cycles_before;
    const internal_cycles = self.cpu.internal_cycles - internal_cycles_before;
    self.advanceClock(fetch_cycles + data_cycles + internal_cycles);
}

fn isTimedIwramTransfer(self: *Machine, instruction: u32) bool {
    // Match unconditional word LDR/STR Rd, [Rn], without offset or writeback.
    if (instruction & 0xFFE0_0FFF != 0xE580_0000) return false;
    const base_register: u4 = @truncate(instruction >> 16);
    const data_register: u4 = @truncate(instruction >> 12);
    if (base_register == 15 or data_register == 15) return false;
    const address = self.cpu.readRegister(base_register);
    return address & 3 == 0 and address >> 24 == Bus.iwram_base >> 24;
}

fn romContainsWord(self: *const Machine, address: u32) bool {
    if (address < Bus.rom_base or address >= 0x0A00_0000) return false;
    return address - Bus.rom_base + 4 <= self.bus.rom.len;
}

fn advanceClock(self: *Machine, cycles: u64) void {
    self.bus.requestInterrupt(self.bus.timers.advance(cycles));
    const old_phase = self.elapsed_cycles % cycles_per_frame;
    const until_vblank = if (old_phase < vblank_start)
        vblank_start - old_phase
    else
        cycles_per_frame - old_phase + vblank_start;
    self.elapsed_cycles += cycles;
    const phase = self.elapsed_cycles % cycles_per_frame;
    self.bus.updateVBlank(phase >= vblank_start and phase < vblank_end, cycles >= until_vblank);
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
    machine.bus.writeData(u16, Bus.dispstat_address, 0b1001);
    try std.testing.expectEqual(@as(u16, 8), machine.bus.readData(u16, Bus.dispstat_address));

    for (0..vblank_start / 20 - 1) |_| try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start - 20), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.readData(u16, Bus.if_address));
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u64, vblank_start), machine.elapsed_cycles);
    try std.testing.expectEqual(@as(u16, 9), machine.bus.readData(u16, Bus.dispstat_address));
    try std.testing.expectEqual(@as(u16, 1), machine.bus.readData(u16, Bus.if_address));
    try std.testing.expect(!machine.bus.irqLine());

    machine.bus.writeData(u16, Bus.if_address, 1);
    try machine.stepTimed();
    try std.testing.expectEqual(@as(u16, 0), machine.bus.readData(u16, Bus.if_address));
}

test "timed ROM fetches use WAITCNT and reject unmodeled prefetch" {
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
    const fetch_cycles = machine.bus.rom_fetch_cycles;
    try std.testing.expectError(error.UntimedPrefetch, machine.stepTimed());
    try std.testing.expectEqual(fetch_cycles, machine.bus.rom_fetch_cycles);
    try std.testing.expectEqual(@as(u64, 47), machine.elapsed_cycles);
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

test "timed stepping rejects a load outside IWRAM before advancing the CPU or clock" {
    const std = @import("std");
    const rom = [_]u8{ 0x00, 0x00, 0x91, 0xE5, 0, 0, 0, 0, 0, 0, 0, 0 }; // LDR r0, [r1]
    var machine: Machine = undefined;
    machine.initCartridge(&rom);
    machine.cpu.registers[1] = Bus.rom_base;
    try std.testing.expectError(error.UntimedInstruction, machine.stepTimed());
    try std.testing.expectEqual(Bus.rom_base, machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u64, 0), machine.elapsed_cycles);
}

test "cartridge SWI executes a BIOS handler that reads a BIOS literal" {
    const std = @import("std");
    const rom = [_]u8{
        0x01, 0x00, 0x00, 0xEF, // SWI
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    const bios = comptime blk: {
        var bytes: [Bus.bios_size_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, bytes[8..12], 0xE59F_0000, .little); // LDR r0, [pc]
        std.mem.writeInt(u32, bytes[16..20], 0x1234_5678, .little);
        break :blk bytes;
    };
    var machine: Machine = undefined;
    machine.initCartridgeWithBios(&rom, &bios);
    try std.testing.expectEqual(@as(u32, 0x0300_7F00), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 8), machine.cpu.instruction_address);
    try std.testing.expectEqual(@as(u32, 0x0300_7FE0), machine.cpu.readRegister(13));
    try machine.step();
    try std.testing.expectEqual(@as(u32, 0x1234_5678), machine.cpu.readRegister(0));
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

test "machine clock routes timer overflow IRQs while delivery is masked" {
    const std = @import("std");
    // Keep the CPU idle to isolate shared-clock device advancement and IRQ latching.
    var machine: Machine = undefined;
    machine.initCartridge(&.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    machine.bus.writeData(u32, 0x0400_0100, 0x00C0_FFFE);
    machine.advanceClock(1);
    try std.testing.expectEqual(@as(u16, 0), machine.bus.irq_flags);
    machine.advanceClock(1);
    try std.testing.expectEqual(@as(u16, 8), machine.bus.irq_flags);
    try std.testing.expect(!machine.bus.irqLine());
    try std.testing.expectEqual(@as(u16, 0xFFFE), machine.bus.readData(u16, 0x0400_0100));
}
