const std = @import("std");
const Bus = @This();
const timing = @import("timing.zig");
const DisplayRegisters = @import("display_registers.zig");
const Audio = @import("audio.zig");
const Timers = @import("timers.zig");
const DMA = @import("dma.zig");
const Serial = @import("serial.zig");

pub const rom_base: u32 = 0x0800_0000;
pub const ewram_base: u32 = 0x0200_0000;
const ewram_size_bytes = 256 * 1024;
pub const iwram_base: u32 = 0x0300_0000;
pub const dispcnt_address: u32 = 0x0400_0000;
pub const dispstat_address: u32 = 0x0400_0004;
pub const vcount_address: u32 = dispstat_address + 2;
const vblank_status: u16 = 1 << 0;
const hblank_status: u16 = 1 << 1;
const vcount_match_status: u16 = 1 << 2;
const display_status_mask: u16 = 7;
const display_write_mask: u16 = 0xFF38;
pub const keyinput_address: u32 = 0x0400_0130;
pub const keycnt_address: u32 = keyinput_address + 2;
const keypad_irq: u14 = 1 << 12;
const keypad_irq_enable: u16 = 1 << 14;
const keypad_match_all: u16 = 1 << 15;
const keypad_control_mask: u16 = 0xC3FF;
pub const ie_address: u32 = 0x0400_0200;
pub const if_address: u32 = 0x0400_0202;
pub const waitcnt_address: u32 = 0x0400_0204;
const waitcnt_write_mask: u16 = 0x5FFF;
const waitcnt_prefetch_enable: u16 = 1 << 14;
pub const ime_address: u32 = 0x0400_0208;
pub const haltcnt_address: u32 = 0x0400_0301;
const haltcnt_stop: u8 = 1 << 7;
pub const bios_size_bytes = 16 * 1024;
const irq_source_mask: u16 = 0x3FFF;
pub const palette_base: u32 = 0x0500_0000;
const palette_size_bytes = 1024;
pub const vram_base: u32 = 0x0600_0000;
const iwram_size_bytes = 32 * 1024;
const vram_size_bytes = 96 * 1024;
pub const oam_base: u32 = 0x0700_0000;
const oam_size_bytes = 1024;

// The caller owns both images and keeps them alive while the bus uses them.
rom: []const u8,
serial: Serial = .{},
dma: DMA = .{},
timers: Timers = .{},
audio: Audio = .{},
pressed_buttons: u10 = 0,
keypad_control: u16 = 0,
display_registers: DisplayRegisters = .{},
bios: ?*const [bios_size_bytes]u8 = null,
executing_bios: bool = false,
halted: bool = false,
ewram: [ewram_size_bytes]u8 = @splat(0),
iwram: [iwram_size_bytes]u8 = @splat(0),
palette: [palette_size_bytes]u8 = @splat(0),
vram: [vram_size_bytes]u8 = @splat(0),
oam: [oam_size_bytes]u8 = @splat(0),
// Display control storage; rendering currently uses only the mode bits.
dispcnt: u16 = 0,
greenswap: u16 = 0,
dispstat: u16 = vcount_match_status,
vcount: u8 = 0,
irq_enable: u16 = 0,
irq_flags: u16 = 0,
ime_enabled: bool = false,
waitcnt: u16 = 0,
bus_cycles: u64 = 0,
rom_fetch_cycles: u64 = 0,
next_rom_data_address: ?u32 = null,
iwram_data_cycles: u64 = 0,
next_fetch_nonsequential: bool = false,

pub fn requestInterrupt(self: *Bus, sources: u14) void {
    // A device latches its request even while IRQ delivery is disabled.
    self.irq_flags |= sources;
}

/// Inject a complete button snapshot between instructions. A set bit means pressed.
/// Bit order is A, B, Select, Start, Right, Left, Up, Down, R, L.
pub fn setPressedButtons(self: *Bus, pressed: u10) void {
    const previous_match = self.keypadIrqCondition();
    self.pressed_buttons = pressed;
    if (!previous_match and self.keypadIrqCondition()) self.requestInterrupt(keypad_irq);
}

fn keypadIrqCondition(self: *const Bus) bool {
    if (self.keypad_control & keypad_irq_enable == 0) return false;
    const selected: u10 = @truncate(self.keypad_control);
    if (selected == 0) return false;
    const matching = selected & self.pressed_buttons;
    if (self.keypad_control & keypad_match_all != 0) return matching == selected;
    return matching != 0;
}

fn writeKeypadControl(self: *Bus, value: u16) void {
    const previous_match = self.keypadIrqCondition();
    self.keypad_control = value & keypad_control_mask;
    // Reevaluate on configuration writes as well as on input changes.
    if (!previous_match and self.keypadIrqCondition()) self.requestInterrupt(keypad_irq);
}

pub fn advanceDevices(self: *Bus, old_phase: u64, cycles: u64) void {
    self.requestInterrupt(self.timers.advance(cycles));
    const phase = (old_phase + cycles) % timing.cycles_per_frame;
    self.vcount = @intCast(phase / timing.cycles_per_line);
    const compare = self.dispstat >> 8;
    const line_phase = phase % timing.cycles_per_line;
    self.dispstat &= ~display_status_mask;
    if (phase >= timing.vblank_start and phase < timing.vblank_end) self.dispstat |= vblank_status;
    if (line_phase >= timing.hblank_start) self.dispstat |= hblank_status;
    if (self.vcount == compare) self.dispstat |= vcount_match_status;

    // Detect crossed event boundaries even if the batch ends after the flag fell.
    var events: u14 = 0;
    if (cycles >= timing.cyclesUntil(old_phase, timing.vblank_start, timing.cycles_per_frame)) {
        events |= 1;
    }
    const old_line_phase = old_phase % timing.cycles_per_line;
    if (cycles >= timing.cyclesUntil(old_line_phase, timing.hblank_start, timing.cycles_per_line)) {
        events |= 2;
    }
    if (compare < timing.lines_per_frame) {
        const edge = @as(u64, compare) * timing.cycles_per_line;
        if (cycles >= timing.cyclesUntil(old_phase, edge, timing.cycles_per_frame)) events |= 4;
    }
    self.requestInterrupt(events & @as(u14, @truncate(self.dispstat >> 3)));
}

fn writeDisplayStatus(self: *Bus, value: u16) void {
    const previously_matching = self.dispstat & vcount_match_status != 0;
    self.dispstat = (self.dispstat & (vblank_status | hblank_status)) |
        (value & display_write_mask);
    if (self.vcount == self.dispstat >> 8) {
        self.dispstat |= vcount_match_status;
        if (!previously_matching and self.dispstat & (1 << 5) != 0) self.requestInterrupt(4);
    }
}

pub fn hasEnabledInterrupt(self: *const Bus) bool {
    return self.irq_enable & self.irq_flags != 0;
}

pub fn irqLine(self: *const Bus) bool {
    return self.ime_enabled and self.hasEnabledInterrupt();
}

pub fn prefetchEnabled(self: *const Bus) bool {
    return self.waitcnt & waitcnt_prefetch_enable != 0;
}

pub fn fetch32(self: *Bus, address: u32, access: timing.Access) u32 {
    return self.fetch(u32, address, access);
}

pub fn fetch16(self: *Bus, address: u32, access: timing.Access) u16 {
    return self.fetch(u16, address, access);
}

fn fetch(self: *Bus, comptime T: type, address: u32, access: timing.Access) T {
    const interrupted = self.next_fetch_nonsequential;
    self.next_fetch_nonsequential = false;
    self.next_rom_data_address = null;
    if (address < bios_size_bytes) {
        self.bus_cycles += 1;
        return self.readBios(T, address);
    }
    if (ewramOffset(address)) |offset| {
        self.next_fetch_nonsequential = true;
        self.bus_cycles += timing.ramAccessCycles(T, @truncate(address >> 24));
        return std.mem.readInt(T, self.ewram[offset..][0..@sizeOf(T)], .little);
    }
    if (iwramOffset(address)) |offset| {
        self.next_fetch_nonsequential = true;
        self.bus_cycles += timing.ramAccessCycles(T, @truncate(address >> 24));
        return std.mem.readInt(T, self.iwram[offset..][0..@sizeOf(T)], .little);
    }
    const value = self.readRom(T, address);
    // The cartridge starts a fresh sequence at each 128 KiB boundary.
    const effective_access = if (interrupted or address & 0x1_FFFF == 0)
        .nonsequential
    else
        access;
    const cycles = timing.gamePakAccessCycles(T, effective_access, self.waitcnt, romWindow(address).?);
    self.rom_fetch_cycles += cycles;
    self.bus_cycles += cycles;
    return value;
}

pub fn readData(self: *Bus, comptime T: type, address: u32) T {
    // The CPU uses the original address to rotate or sign-extend the aligned value.
    const aligned_address = alignDataAddress(T, address);
    self.chargeDataAccess(T, aligned_address);
    if (aligned_address < bios_size_bytes) {
        // External BIOS reads need a protected-read latch, not access to ROM bytes.
        if (!self.executing_bios) @panic("protected BIOS data read not modeled");
        return self.readBios(T, aligned_address);
    }
    if (aligned_address >= ie_address and aligned_address + @sizeOf(T) <= 0x0400_020C) {
        var result: T = 0;
        for (0..@sizeOf(T)) |index| {
            const byte_address = aligned_address + @as(u32, @intCast(index));
            const halfword: u16 = switch (byte_address & ~@as(u32, 1)) {
                ie_address => self.irq_enable,
                if_address => self.irq_flags,
                waitcnt_address => self.waitcnt,
                ime_address => @intFromBool(self.ime_enabled),
                else => 0,
            };
            const byte: u8 = @truncate(halfword >> @intCast((byte_address & 1) * 8));
            result |= @as(T, byte) << @intCast(index * 8);
        }
        return result;
    }
    if (Audio.contains(aligned_address)) return self.audio.read(T, aligned_address);
    if (Timers.contains(aligned_address)) return self.timers.read(T, aligned_address);
    if (DMA.contains(aligned_address)) return self.dma.read(T, aligned_address);
    if (aligned_address >= keyinput_address and aligned_address < keyinput_address + 4) {
        const input: u16 = @as(u10, ~self.pressed_buttons);
        const registers = @as(u32, input) | (@as(u32, self.keypad_control) << 16);
        const shift: u5 = @intCast((aligned_address - keyinput_address) * 8);
        return @truncate(registers >> shift);
    }
    if (Serial.contains(aligned_address)) return self.serial.read(T, aligned_address);
    if (ewramOffset(aligned_address)) |offset| {
        self.next_fetch_nonsequential = true;
        return std.mem.readInt(T, self.ewram[offset..][0..@sizeOf(T)], .little);
    }
    if (iwramOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.iwram[offset..][0..@sizeOf(T)], .little);
    }
    if (paletteOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.palette[offset..][0..@sizeOf(T)], .little);
    }
    if (aligned_address >> 24 == vram_base >> 24) {
        const offset = self.vramOffset(aligned_address) orelse return 0;
        return std.mem.readInt(T, self.vram[offset..][0..@sizeOf(T)], .little);
    }
    if (oamOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.oam[offset..][0..@sizeOf(T)], .little);
    }
    if (aligned_address >= dispcnt_address and aligned_address < dispcnt_address + 8) {
        const word = if (aligned_address < dispstat_address)
            @as(u32, self.dispcnt) | (@as(u32, self.greenswap) << 16)
        else
            @as(u32, self.dispstat) | (@as(u32, self.vcount) << 16);
        const shift: u5 = @intCast((aligned_address & 3) * 8);
        return @truncate(word >> shift);
    }
    return self.readRom(T, aligned_address);
}

pub fn writeData(self: *Bus, comptime T: type, address: u32, value: T) void {
    const aligned_address = alignDataAddress(T, address);
    self.chargeDataAccess(T, aligned_address);
    self.writeAligned(T, aligned_address, value);
}

fn writeAligned(self: *Bus, comptime T: type, aligned_address: u32, value: T) void {
    if (T == u8 and aligned_address == haltcnt_address) {
        if (!self.executing_bios) return;
        if (value & haltcnt_stop != 0) @panic("GBA STOP mode is unsupported");
        self.halted = true;
        return;
    }
    if (aligned_address >= ie_address and aligned_address + @sizeOf(T) <= 0x0400_020C) {
        for (0..@sizeOf(T)) |index| {
            const byte_address = aligned_address + @as(u32, @intCast(index));
            const shift: u4 = @intCast((byte_address & 1) * 8);
            const byte: u8 = @truncate(value >> @intCast(index * 8));
            const bits = @as(u16, byte) << shift;
            const preserve = ~(@as(u16, 0xFF) << shift);
            switch (byte_address & ~@as(u32, 1)) {
                ie_address => self.irq_enable = ((self.irq_enable & preserve) | bits) & irq_source_mask,
                // IF acknowledges only the written byte, without a read-modify-write.
                if_address => self.irq_flags &= ~bits,
                waitcnt_address => {
                    self.waitcnt = ((self.waitcnt & preserve) | bits) & waitcnt_write_mask;
                    self.next_fetch_nonsequential = true;
                },
                ime_address => if (shift == 0) {
                    self.ime_enabled = byte & 1 != 0;
                },
                else => {}, // Unused halfwords at 0x206 and 0x20A.
            }
        }
        return;
    }
    if (T == u8 and aligned_address >= dispcnt_address and
        aligned_address < 0x0400_0058)
    {
        const halfword_address = aligned_address & ~@as(u32, 1);
        const previous: u16 = switch (halfword_address) {
            dispcnt_address => self.dispcnt,
            dispcnt_address + 2 => self.greenswap,
            dispstat_address => self.dispstat,
            vcount_address => 0,
            else => self.display_registers.stored(halfword_address),
        };
        const shift: u4 = @intCast((aligned_address & 1) * 8);
        const merged = (previous & ~(@as(u16, 0xFF) << shift)) | (@as(u16, value) << shift);
        self.writeAligned(u16, halfword_address, merged);
        return;
    }
    if (T == u32 and aligned_address >= dispcnt_address and
        aligned_address < 0x0400_0058)
    {
        self.writeAligned(u16, aligned_address, @truncate(value));
        self.writeAligned(u16, aligned_address + 2, @truncate(value >> 16));
        return;
    }
    if (paletteOffset(aligned_address)) |offset| {
        if (T == u8) {
            // Palette RAM drives both byte lanes on a byte store.
            const halfword_offset = offset & ~@as(u32, 1);
            self.palette[halfword_offset..][0..2].* = @splat(value);
        } else {
            std.mem.writeInt(T, self.palette[offset..][0..@sizeOf(T)], value, .little);
        }
        return;
    }
    if (T == u16) {
        if (aligned_address == vcount_address) return; // VCOUNT is read-only.
        if (DisplayRegisters.contains(aligned_address)) {
            self.display_registers.write(aligned_address, value);
            return;
        }
    }
    if (Audio.contains(aligned_address)) {
        self.audio.write(T, aligned_address, value);
        return;
    }
    if (Timers.contains(aligned_address)) {
        self.timers.write(T, aligned_address, value);
        return;
    }
    if (DMA.contains(aligned_address)) {
        self.dma.write(T, aligned_address, value);
        return;
    }
    // The BIOS clears the unused word between serial registers and KEYINPUT.
    if (aligned_address >= 0x0400_012C and aligned_address < keyinput_address) return;
    // The BIOS also clears the unused I/O after JOYSTAT.
    if (aligned_address >= 0x0400_015C and aligned_address < ie_address) return;
    // The reset loop also clears the unused gap between RCNT and JOYCNT.
    if (aligned_address >= 0x0400_0138 and aligned_address < 0x0400_0140) return;
    if (aligned_address >= keyinput_address and aligned_address < keyinput_address + 4) {
        // KEYINPUT is read-only, including the lower half of a word write.
        if (T == u32) {
            self.writeKeypadControl(@truncate(value >> 16));
        } else if (aligned_address >= keycnt_address) {
            if (T == u16) {
                self.writeKeypadControl(value);
            } else {
                const shift: u4 = @intCast((aligned_address - keycnt_address) * 8);
                const keep = self.keypad_control & ~(@as(u16, 0xFF) << shift);
                self.writeKeypadControl(keep | (@as(u16, value) << shift));
            }
        }
        return;
    }
    if (Serial.contains(aligned_address)) {
        self.serial.write(T, aligned_address, value);
        return;
    }
    if (T == u16) {
        if (aligned_address == dispcnt_address) {
            self.dispcnt = value;
            return;
        }
        if (aligned_address == dispcnt_address + 2) {
            self.greenswap = value & 1;
            return;
        }
        if (aligned_address == dispstat_address) {
            self.writeDisplayStatus(value);
            return;
        }
    }
    if (aligned_address >> 24 == vram_base >> 24) {
        const offset = self.vramOffset(aligned_address) orelse return;
        if (T == u8) {
            // Byte writes duplicate in background VRAM and are ignored in sprite VRAM.
            const sprite_start: u32 = if (self.bitmapMode()) 0x14000 else 0x10000;
            if (offset >= sprite_start) return;
            self.vram[offset & ~@as(u32, 1) ..][0..2].* = @splat(value);
        } else {
            std.mem.writeInt(T, self.vram[offset..][0..@sizeOf(T)], value, .little);
        }
        return;
    }
    if (oamOffset(aligned_address)) |offset| {
        // The OAM bus ignores byte stores, including stores through mirrored addresses.
        if (T != u8) std.mem.writeInt(T, self.oam[offset..][0..@sizeOf(T)], value, .little);
        return;
    }
    // The gap between DMA and timers is unused.
    if (aligned_address >= DMA.end and
        aligned_address + @sizeOf(T) <= 0x0400_0100) return;
    // The gap between display and sound registers has no write side effects.
    if (aligned_address >= 0x0400_0058 and
        aligned_address + @sizeOf(T) <= 0x0400_0060) return;
    // The gap between timers and serial registers has no write side effects.
    // Keep real peripheral registers outside this range visible as unsupported.
    if (aligned_address >= 0x0400_0110 and
        aligned_address + @sizeOf(T) <= 0x0400_0120) return;
    if (ewramOffset(aligned_address)) |offset| {
        std.mem.writeInt(T, self.ewram[offset..][0..@sizeOf(T)], value, .little);
        self.next_fetch_nonsequential = true;
        return;
    }
    const offset = iwramOffset(aligned_address) orelse
        std.debug.panic("unmapped {d}-bit data write at 0x{x:0>8}", .{ @bitSizeOf(T), aligned_address });
    std.mem.writeInt(T, self.iwram[offset..][0..@sizeOf(T)], value, .little);
}

fn chargeDataAccess(self: *Bus, comptime T: type, address: u32) void {
    self.next_fetch_nonsequential = true;
    if (romWindow(address)) |window| {
        const sequential = self.next_rom_data_address == address and address & 0x1_FFFF != 0;
        const access: timing.Access = if (sequential) .sequential else .nonsequential;
        self.bus_cycles += timing.gamePakAccessCycles(T, access, self.waitcnt, window);
        self.next_rom_data_address = (address & ~@as(u32, 1)) + @max(2, @sizeOf(T));
    } else {
        self.next_rom_data_address = null;
        const region: u8 = @truncate(address >> 24);
        const cycles = timing.ramAccessCycles(T, region);
        self.bus_cycles += cycles;
        if (region == iwram_base >> 24) self.iwram_data_cycles += cycles;
    }
}

fn alignDataAddress(comptime T: type, address: u32) u32 {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    return address & ~@as(u32, @sizeOf(T) - 1);
}

fn ewramOffset(address: u32) ?u32 {
    if (address >> 24 != ewram_base >> 24) return null;
    return address % ewram_size_bytes;
}

fn iwramOffset(address: u32) ?u32 {
    if (address >> 24 != iwram_base >> 24) return null;
    return address % iwram_size_bytes;
}

fn paletteOffset(address: u32) ?u32 {
    if (address >> 24 != palette_base >> 24) return null;
    return address % palette_size_bytes;
}

fn oamOffset(address: u32) ?u32 {
    if (address >> 24 != oam_base >> 24) return null;
    return address % oam_size_bytes;
}

fn bitmapMode(self: *const Bus) bool {
    return self.dispcnt & 7 >= 3;
}

fn vramOffset(self: *const Bus, address: u32) ?u32 {
    std.debug.assert(address >> 24 == vram_base >> 24);
    const offset = address & 0x1FFFF;
    if (offset < vram_size_bytes) return offset;
    // The final 32 KiB aliases the preceding bank, except in bitmap modes
    // where the first 16 KiB of that alias reads zero and discards writes.
    if (self.bitmapMode() and offset < 0x1C000) return null;
    return offset - 0x8000;
}

fn readBios(self: *const Bus, comptime T: type, address: u32) T {
    const bios = self.bios orelse @panic("BIOS access without a BIOS image");
    return std.mem.readInt(T, bios[address..][0..@sizeOf(T)], .little);
}

fn readRom(self: *const Bus, comptime T: type, address: u32) T {
    if (romWindow(address) == null) {
        std.debug.panic("unmapped {d}-bit read at 0x{x:0>8}", .{ @bitSizeOf(T), address });
    }
    const offset = address & 0x01FF_FFFF;
    if (offset + @sizeOf(T) <= self.rom.len) {
        return std.mem.readInt(T, self.rom[offset..][0..@sizeOf(T)], .little);
    }

    // Unbacked Game Pak ROM returns the low 16 bits of the halfword address.
    // Preserve file bytes in a transfer that straddles the end of the image.
    var result: T = 0;
    for (0..@sizeOf(T)) |index| {
        const byte_offset = offset + @as(u32, @intCast(index));
        const byte = if (byte_offset < self.rom.len)
            self.rom[byte_offset]
        else
            unbackedRomByte(rom_base + byte_offset);
        result |= @as(T, byte) << @intCast(index * 8);
    }
    return result;
}

fn romWindow(address: u32) ?u2 {
    if (address < rom_base or address >= 0x0E00_0000) return null;
    return @intCast((address - rom_base) >> 25);
}

fn unbackedRomByte(address: u32) u8 {
    const halfword_address: u16 = @truncate(address >> 1);
    const shift: u4 = @intCast((address & 1) * 8);
    return @truncate(halfword_address >> shift);
}

test "unbacked Game Pak data follows the halfword address on each byte lane" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    try std.testing.expectEqual(@as(u32, 0x0003_6655), bus.readData(u32, rom_base + 4));
    try std.testing.expectEqual(@as(u32, 0x0283_0282), bus.readData(u32, rom_base + 0x504));
    try std.testing.expectEqual(@as(u8, 0x82), bus.readData(u8, rom_base + 0x504));
    try std.testing.expectEqual(@as(u8, 0x02), bus.readData(u8, rom_base + 0x505));
    try std.testing.expectEqual(@as(u16, 0x0283), bus.fetch16(rom_base + 0x506, .sequential));
}

test "WAITCNT masks reserved bits and exposes the prefetch enable bit" {
    var bus: Bus = .{ .rom = &.{} };
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, waitcnt_address));
    try std.testing.expect(!bus.prefetchEnabled());
    bus.writeData(u16, waitcnt_address, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x5FFF), bus.readData(u16, waitcnt_address));
    try std.testing.expect(bus.prefetchEnabled());
}

test "IRQ requests latch while masked and IF acknowledges only written ones" {
    var bus: Bus = .{ .rom = &.{} };
    bus.requestInterrupt(0b11);
    try std.testing.expectEqual(@as(u16, 3), bus.readData(u16, if_address));
    try std.testing.expect(!bus.irqLine());

    bus.writeData(u16, ime_address, 1);
    try std.testing.expect(!bus.irqLine());
    bus.writeData(u16, ie_address, 1);
    try std.testing.expect(bus.irqLine());
    bus.writeData(u16, if_address, 0);
    try std.testing.expect(bus.irqLine());
    bus.writeData(u32, ie_address, 0x0001_C001);
    try std.testing.expectEqual(@as(u32, 0x0002_0001), bus.readData(u32, ie_address));
    try std.testing.expect(!bus.irqLine());
}

test "IME shares bit zero across access widths and ignores other bits" {
    var bus: Bus = .{ .rom = &.{} };
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, ime_address));

    bus.writeData(u32, ime_address, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u16, 1), bus.readData(u16, ime_address));
    try std.testing.expectEqual(@as(u32, 1), bus.readData(u32, ime_address));

    bus.writeData(u16, ime_address, 0xFFFE);
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, ime_address));

    bus.writeData(u8, ime_address, 1);
    try std.testing.expectEqual(@as(u16, 1), bus.readData(u16, ime_address));
}

test "Thumb fetch reads two bytes at a halfword offset" {
    var bus: Bus = .{ .rom = &.{ 0x00, 0x20, 0x2A, 0x21 } };
    try std.testing.expectEqual(@as(u16, 0x212A), bus.fetch16(rom_base + 2, .sequential));
    try std.testing.expectEqual(@as(u64, 3), bus.rom_fetch_cycles);
    _ = bus.fetch16(rom_base, .sequential);
    try std.testing.expectEqual(@as(u64, 8), bus.rom_fetch_cycles);
}

test "ROM data reads align to their transfer width without rotating" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    const address = rom_base + 3;
    try std.testing.expectEqual(@as(u8, 0x44), bus.readData(u8, address));
    try std.testing.expectEqual(@as(u16, 0x4433), bus.readData(u16, address));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, address));
}

test "writes to the unused timer to serial gap leave bus state unchanged" {
    // Exercise every transfer width used by BIOS register clearing loops.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, ie_address, 3);
    for (0x0400_0110..0x0400_0120) |address| {
        bus.writeData(u8, @intCast(address), 0xFF);
        bus.writeData(u16, @intCast(address), 0xFFFF);
        bus.writeData(u32, @intCast(address), 0xFFFF_FFFF);
    }
    try std.testing.expectEqual(@as(u16, 3), bus.irq_enable);
    try std.testing.expectEqual(@as(u64, 0), bus.iwram_data_cycles);
    try std.testing.expect(bus.next_fetch_nonsequential);
}

test "bus routes serial registers across access widths" {
    // Verify dispatch and CPU alignment without involving a ROM or BIOS.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, Serial.base, 0x1234_5678);
    bus.writeData(u8, Serial.base + 1, 0xAB);
    try std.testing.expectEqual(@as(u16, 0xAB78), bus.readData(u16, Serial.base));
    try std.testing.expectEqual(@as(u32, 0x1234_AB78), bus.readData(u32, Serial.base));
}

test "display control word writes include the green swap register" {
    // BIOS block stores use words across adjacent 16-bit display registers.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, dispcnt_address, 0xFFFF_0403);
    try std.testing.expectEqual(@as(u16, 0x0403), bus.readData(u16, dispcnt_address));
    try std.testing.expectEqual(@as(u32, 0x0001_0403), bus.readData(u32, dispcnt_address));
    bus.writeData(u16, dispcnt_address + 2, 2);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, dispcnt_address + 2));
}

test "BIOS display reset word stores and byte updates preserve status" {
    // Exercise the complete display reset span, including read-only and unused addresses.
    var bus: Bus = .{ .rom = &.{} };
    bus.advanceDevices(0, timing.vblank_start);
    for (0..0x60 / 4) |index| {
        bus.writeData(u32, dispcnt_address + @as(u32, @intCast(index * 4)), 0);
    }
    try std.testing.expectEqual(@as(u16, 1), bus.dispstat);
    bus.writeData(u8, dispcnt_address + 1, 4);
    bus.writeData(u8, dispcnt_address, 3);
    try std.testing.expectEqual(@as(u16, 0x0403), bus.dispcnt);
    bus.writeData(u8, 0x0400_0011, 0xFF);
    try std.testing.expectEqual(@as(u16, 0x0100), bus.display_registers.values[4]);
}

test "system control byte lanes preserve masks and acknowledge only written IF bits" {
    var bus: Bus = .{ .rom = &.{} };
    bus.requestInterrupt(0x3FFF);
    bus.writeData(u8, if_address + 1, 1);
    try std.testing.expectEqual(@as(u16, 0x3EFF), bus.readData(u16, if_address));
    bus.writeData(u8, ie_address + 1, 0xFF);
    bus.writeData(u8, ie_address, 0x55);
    try std.testing.expectEqual(@as(u16, 0x3F55), bus.readData(u16, ie_address));
    bus.writeData(u32, waitcnt_address, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x5FFF), bus.readData(u32, waitcnt_address));
    bus.writeData(u8, waitcnt_address, 0);
    try std.testing.expectEqual(@as(u16, 0x5F00), bus.readData(u16, waitcnt_address));
    bus.writeData(u32, ime_address, 1);
    bus.writeData(u8, ime_address + 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 1), bus.readData(u32, ime_address));
}

test "BIOS DMA reset stores reach every channel and the unused trailing gap" {
    // Word stores must route to channels without accidentally touching timers.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, DMA.base, 0x0300_1234);
    bus.writeData(u16, DMA.base + 10, 0x4000);
    try std.testing.expectEqual(@as(u16, 0x4000), bus.readData(u16, DMA.base + 10));
    for (0..(0x100 - 0xB0) / 4) |index| {
        bus.writeData(u32, DMA.base + @as(u32, @intCast(index * 4)), 0);
    }
    for (bus.dma.channels) |channel| {
        try std.testing.expectEqualDeep(DMA.Channel{}, channel);
    }
}

test "keypad word accesses pair active-low input with masked control" {
    var bus: Bus = .{ .rom = &.{} };
    try std.testing.expectEqual(@as(u32, 0x0000_03FF), bus.readData(u32, keyinput_address));
    bus.setPressedButtons(0x201);
    bus.writeData(u32, keyinput_address, 0xFFFF_0000);
    try std.testing.expectEqual(@as(u32, 0xC3FF_01FE), bus.readData(u32, keyinput_address));
    bus.writeData(u8, keycnt_address, 0x01);
    bus.writeData(u8, keyinput_address + 1, 0xFF);
    try std.testing.expectEqual(@as(u8, 1), bus.readData(u8, keyinput_address + 1));
    try std.testing.expectEqual(@as(u16, 0xC301), bus.readData(u16, keycnt_address));
}

test "keypad any and all matches latch IF independently of CPU delivery" {
    var bus: Bus = .{ .rom = &.{} };
    bus.setPressedButtons(1);
    bus.writeData(u16, keycnt_address, 0x4003);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
    try std.testing.expect(!bus.irqLine());
    bus.writeData(u16, if_address, keypad_irq);
    bus.writeData(u16, keycnt_address, 0xC003);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.setPressedButtons(7);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
    bus.writeData(u16, if_address, keypad_irq);
    bus.setPressedButtons(7);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.setPressedButtons(0);
    bus.setPressedButtons(3);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
}

test "palette RAM mirrors share storage and byte writes update only the addressed color" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, palette_base + 0x1FC, 0x7C00_1234);
    bus.writeData(u8, palette_base + 0x5FD, 0x5A);
    try std.testing.expectEqual(@as(u32, 0x7C00_5A5A), bus.readData(u32, palette_base + 0x1FC));
    try std.testing.expectEqual(@as(u8, 0x7C), bus.readData(u8, palette_base + 0x5FF));
    bus.writeData(u16, 0x05FF_FFFE, 0xFEDC);
    try std.testing.expectEqual(@as(u16, 0xFEDC), bus.readData(u16, palette_base + 0x3FE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, palette_base));
}

test "VRAM widths and mirrors share storage with a hole in bitmap modes" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, vram_base + 0x30000, 0x4433_2211);
    try std.testing.expectEqual(@as(u8, 0x33), bus.readData(u8, vram_base + 0x18002));
    try std.testing.expectEqual(@as(u16, 0x2211), bus.readData(u16, vram_base + 0x10000));
    bus.writeData(u16, dispcnt_address, 3);
    bus.writeData(u32, vram_base + 0x18000, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, vram_base + 0x18000));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, vram_base + 0x10000));
    bus.writeData(u32, vram_base + 0x1FFFC, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), bus.readData(u32, vram_base + 0x17FFC));
}

test "VRAM byte stores honor the background and sprite boundary" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u8, vram_base + 0xFFFF, 0x12);
    bus.writeData(u8, vram_base + 0x10000, 0x34);
    try std.testing.expectEqual(@as(u16, 0x1212), bus.readData(u16, vram_base + 0xFFFE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vram_base + 0x10000));
    bus.writeData(u16, dispcnt_address, 3);
    bus.writeData(u8, vram_base + 0x13FFF, 0x56);
    bus.writeData(u8, vram_base + 0x1C000, 0x78);
    try std.testing.expectEqual(@as(u16, 0x5656), bus.readData(u16, vram_base + 0x13FFE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vram_base + 0x14000));
}

test "OAM mirrors preserve both sprite attributes and affine coefficients" {
    var bus: Bus = .{ .rom = &.{} };
    // The last two halfwords hold a sprite attribute and an affine coefficient.
    bus.writeData(u32, oam_base + 0x7FC, 0xFEDC_1234);
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readData(u16, oam_base + 0x3FC));
    try std.testing.expectEqual(@as(u8, 0xFE), bus.readData(u8, 0x07FF_FFFF));
    bus.writeData(u8, oam_base + 0x3FD, 0);
    bus.writeData(u8, 0x07FF_FFFE, 0);
    try std.testing.expectEqual(@as(u32, 0xFEDC_1234), bus.readData(u32, oam_base + 0x3FC));
    bus.writeData(u16, 0x07FF_FFFE, 0x0100);
    try std.testing.expectEqual(@as(u32, 0x0100_1234), bus.readData(u32, oam_base + 0x7FC));
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, oam_base));
}

test "EWRAM data and instruction accesses share mirrored storage" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, ewram_base + 0x40001, 0x4433_2211);
    bus.writeData(u8, ewram_base + 1, 0xAA);
    bus.writeData(u16, 0x02FC_0003, 0x6655);
    try std.testing.expectEqual(@as(u32, 0x6655_AA11), bus.readData(u32, ewram_base));
    try std.testing.expectEqual(@as(u8, 0x55), bus.readData(u8, ewram_base + 0x80002));
    try std.testing.expectEqual(@as(u16, 0x6655), bus.fetch16(ewram_base + 0xC0002, .sequential));
    try std.testing.expectEqual(@as(u32, 0x6655_AA11), bus.fetch32(ewram_base, .nonsequential));
    bus.writeData(u16, 0x02FF_FFFE, 0xCDEF);
    try std.testing.expectEqual(@as(u16, 0xCDEF), bus.readData(u16, ewram_base + 0x3FFFE));
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, iwram_base));
}

test "the mirrored IRQ handler address shares the top word of IWRAM" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, 0x03FF_FFFC, 0x0800_0100);
    try std.testing.expectEqual(@as(u32, 0x0800_0100), bus.readData(u32, 0x0300_7FFC));
}

test "IWRAM loaded as data can execute through its mirrors" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, iwram_base + 4, 0xE1A0_0000);
    try std.testing.expectEqual(@as(u32, 0xE1A0_0000), bus.fetch32(0x03FF_8004, .nonsequential));
    try std.testing.expectEqual(@as(u16, 0xE1A0), bus.fetch16(iwram_base + 6, .sequential));
    try std.testing.expectEqual(@as(u64, 0), bus.rom_fetch_cycles);
}

test "display timing updates scanline status and latches each enabled IRQ" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, dispstat_address, 0xA0FF);
    try std.testing.expectEqual(@as(u16, 0xA038), bus.readData(u16, dispstat_address));
    bus.advanceDevices(0, timing.hblank_start - 1);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.advanceDevices(timing.hblank_start - 1, 1);
    try std.testing.expectEqual(@as(u16, 0xA03A), bus.readData(u16, dispstat_address));
    try std.testing.expectEqual(@as(u16, 2), bus.irq_flags);
    bus.writeData(u16, if_address, 2);
    bus.advanceDevices(timing.vblank_start - 1, 1);
    try std.testing.expectEqual(@as(u32, 0x00A0_A03D), bus.readData(u32, dispstat_address));
    try std.testing.expectEqual(@as(u16, 5), bus.irq_flags);
    bus.writeData(u32, dispstat_address, 0xFFFF_A038);
    try std.testing.expectEqual(@as(u8, 160), bus.readData(u8, vcount_address));
    bus.advanceDevices(timing.vblank_start, timing.vblank_end - timing.vblank_start);
    try std.testing.expectEqual(@as(u32, 0x00E3_A038), bus.readData(u32, dispstat_address));
    bus.advanceDevices(timing.vblank_end, timing.cycles_per_line);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vcount_address));
}

test "Game Pak mirrors use their own wait states and restart at a page boundary" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, 0x0A00_0000));
    try std.testing.expectEqual(@as(u64, 10), bus.bus_cycles);
    _ = bus.readData(u32, 0x0A00_0004);
    try std.testing.expectEqual(@as(u64, 20), bus.bus_cycles);
    _ = bus.readData(u16, 0x0C01_FFFE);
    _ = bus.readData(u16, 0x0C02_0000);
    try std.testing.expectEqual(@as(u64, 30), bus.bus_cycles);
    try std.testing.expectEqual(@as(u16, 0x2211), bus.fetch16(0x0C00_0000, .sequential));
    try std.testing.expectEqual(@as(u64, 35), bus.bus_cycles);
}
