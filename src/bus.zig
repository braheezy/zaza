const std = @import("std");
const Bus = @This();
const timing = @import("timing.zig");

pub const rom_base: u32 = 0x0800_0000;
pub const iwram_base: u32 = 0x0300_0000;
pub const dispcnt_address: u32 = 0x0400_0000;
pub const dispstat_address: u32 = 0x0400_0004;
const vblank_status: u16 = 1 << 0;
const vblank_irq_enable: u16 = 1 << 3;
pub const ie_address: u32 = 0x0400_0200;
pub const if_address: u32 = 0x0400_0202;
pub const ime_address: u32 = 0x0400_0208;
pub const bios_size_bytes = 16 * 1024;
const irq_source_mask: u16 = 0x3FFF;
pub const vram_base: u32 = 0x0600_0000;
const iwram_size_bytes = 32 * 1024;
const vram_size_bytes = 96 * 1024;

// The caller owns the ROM bytes and keeps them alive while the bus uses them.
rom: []const u8,
bios: ?*const [bios_size_bytes]u8 = null,
iwram: [iwram_size_bytes]u8 = @splat(0),
vram: [vram_size_bytes]u8 = @splat(0),
// Only halfword storage is modeled; there is no display behavior yet.
dispcnt: u16 = 0,
// Only the VBlank status and IRQ enable bits are modeled.
dispstat: u16 = 0,
irq_enable: u16 = 0,
irq_flags: u16 = 0,
ime_enabled: bool = false,
rom_fetch_cycles: u64 = 0,

pub fn requestInterrupt(self: *Bus, sources: u14) void {
    // A device latches its request even while IRQ delivery is disabled.
    self.irq_flags |= sources;
}

pub fn updateVBlank(self: *Bus, active: bool, started: bool) void {
    self.dispstat = (self.dispstat & ~vblank_status) | @intFromBool(active);
    if (started and self.dispstat & vblank_irq_enable != 0) self.requestInterrupt(1);
}

pub fn irqLine(self: *const Bus) bool {
    return self.ime_enabled and (self.irq_enable & self.irq_flags) != 0;
}

pub fn fetch32(self: *Bus, address: u32, access: timing.Access) u32 {
    return self.fetch(u32, address, access);
}

pub fn fetch16(self: *Bus, address: u32, access: timing.Access) u16 {
    return self.fetch(u16, address, access);
}

fn fetch(self: *Bus, comptime T: type, address: u32, access: timing.Access) T {
    if (address < bios_size_bytes) {
        const bios = self.bios orelse @panic("BIOS fetch without a BIOS image");
        return std.mem.readInt(T, bios[address..][0..@sizeOf(T)], .little);
    }
    const value = self.readRom(T, address);
    // The cartridge starts a fresh sequence at each 128 KiB boundary.
    const effective_access = if (address & 0x1_FFFF == 0) .nonsequential else access;
    self.rom_fetch_cycles += timing.gamePak0AccessCycles(T, effective_access);
    return value;
}

pub fn readData(self: *const Bus, comptime T: type, address: u32) T {
    // The CPU uses the original address to rotate or sign-extend the aligned value.
    const aligned_address = alignDataAddress(T, address);
    if (iwramOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.iwram[offset..][0..@sizeOf(T)], .little);
    }
    if (T == u16) {
        if (aligned_address == ie_address) return self.irq_enable;
        if (aligned_address == if_address) return self.irq_flags;
        if (aligned_address == dispcnt_address) return self.dispcnt;
        if (aligned_address == dispstat_address) return self.dispstat;
        if (vramOffset(aligned_address)) |offset| {
            return std.mem.readInt(u16, self.vram[offset..][0..2], .little);
        }
    }
    if (T == u32 and aligned_address == ie_address) {
        return @as(u32, self.irq_enable) | (@as(u32, self.irq_flags) << 16);
    }
    if (aligned_address == ime_address) return @intFromBool(self.ime_enabled);
    return self.readRom(T, aligned_address);
}

pub fn writeData(self: *Bus, comptime T: type, address: u32, value: T) void {
    const aligned_address = alignDataAddress(T, address);
    if (T == u16) {
        if (aligned_address == ie_address) {
            self.irq_enable = value & irq_source_mask;
            return;
        }
        if (aligned_address == if_address) {
            // Software acknowledges requests by writing ones to the corresponding bits.
            self.irq_flags &= ~value;
            return;
        }
        if (aligned_address == dispcnt_address) {
            self.dispcnt = value;
            return;
        }
        if (aligned_address == dispstat_address) {
            self.dispstat = (self.dispstat & vblank_status) | (value & vblank_irq_enable);
            return;
        }
        if (vramOffset(aligned_address)) |offset| {
            std.mem.writeInt(u16, self.vram[offset..][0..2], value, .little);
            return;
        }
    }
    if (T == u32 and aligned_address == ie_address) {
        // The low halfword writes IE; the high halfword acknowledges IF.
        self.irq_enable = @as(u16, @truncate(value)) & irq_source_mask;
        self.irq_flags &= ~@as(u16, @truncate(value >> 16));
        return;
    }
    if (aligned_address == ime_address) {
        self.ime_enabled = value & 1 != 0;
        return;
    }
    const offset = iwramOffset(aligned_address) orelse
        std.debug.panic("unmapped {d}-bit data write at 0x{x:0>8}", .{ @bitSizeOf(T), address });
    std.mem.writeInt(T, self.iwram[offset..][0..@sizeOf(T)], value, .little);
}

fn alignDataAddress(comptime T: type, address: u32) u32 {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    return address & ~@as(u32, @sizeOf(T) - 1);
}

fn iwramOffset(address: u32) ?u32 {
    if (address < iwram_base or address >= iwram_base + iwram_size_bytes) return null;
    return address - iwram_base;
}

fn vramOffset(address: u32) ?u32 {
    // Only the base VRAM range is mapped; mirrored addresses are not handled yet.
    if (address < vram_base or address >= vram_base + vram_size_bytes) return null;
    return address - vram_base;
}

fn readRom(self: *const Bus, comptime T: type, address: u32) T {
    // Only the first cartridge window is mapped in this initial bus.
    if (address < rom_base or address >= 0x0A00_0000) {
        std.debug.panic("unmapped {d}-bit read at 0x{x:0>8}", .{ @bitSizeOf(T), address });
    }
    const offset = address - rom_base;
    if (offset + @sizeOf(T) > self.rom.len) @panic("read past end of ROM");
    return std.mem.readInt(T, self.rom[offset..][0..@sizeOf(T)], .little);
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
    const bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    const address = rom_base + 3;
    try std.testing.expectEqual(@as(u8, 0x44), bus.readData(u8, address));
    try std.testing.expectEqual(@as(u16, 0x4433), bus.readData(u16, address));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, address));
}
