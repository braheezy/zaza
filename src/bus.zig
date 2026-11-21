const std = @import("std");
const Bus = @This();

pub const rom_base: u32 = 0x0800_0000;
pub const iwram_base: u32 = 0x0300_0000;
pub const dispcnt_address: u32 = 0x0400_0000;
pub const ime_address: u32 = 0x0400_0208;
pub const vram_base: u32 = 0x0600_0000;
const iwram_size_bytes = 32 * 1024;
const vram_size_bytes = 96 * 1024;

// The caller owns the ROM bytes and keeps them alive while the bus uses them.
rom: []const u8,
iwram: [iwram_size_bytes]u8 = @splat(0),
vram: [vram_size_bytes]u8 = @splat(0),
// Only halfword storage is modeled; there is no display behavior yet.
dispcnt: u16 = 0,
// Interrupt delivery is not wired yet; only the master enable latch is modeled.
ime_enabled: bool = false,

pub fn fetch32(self: *const Bus, address: u32) u32 {
    return self.readRom(u32, address);
}

pub fn fetch16(self: *const Bus, address: u32) u16 {
    return self.readRom(u16, address);
}

pub fn readData(self: *const Bus, comptime T: type, address: u32) T {
    // The CPU uses the original address to rotate or sign-extend the aligned value.
    const aligned_address = alignDataAddress(T, address);
    if (iwramOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.iwram[offset..][0..@sizeOf(T)], .little);
    }
    if (T == u16) {
        if (aligned_address == dispcnt_address) return self.dispcnt;
        if (vramOffset(aligned_address)) |offset| {
            return std.mem.readInt(u16, self.vram[offset..][0..2], .little);
        }
    }
    if (aligned_address == ime_address) return @intFromBool(self.ime_enabled);
    return self.readRom(T, aligned_address);
}

pub fn writeData(self: *Bus, comptime T: type, address: u32, value: T) void {
    const aligned_address = alignDataAddress(T, address);
    if (T == u16) {
        if (aligned_address == dispcnt_address) {
            self.dispcnt = value;
            return;
        }
        if (vramOffset(aligned_address)) |offset| {
            std.mem.writeInt(u16, self.vram[offset..][0..2], value, .little);
            return;
        }
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
    const bus: Bus = .{ .rom = &.{ 0x00, 0x20, 0x2A, 0x21 } };
    try std.testing.expectEqual(@as(u16, 0x212A), bus.fetch16(rom_base + 2));
}

test "ROM data reads align to their transfer width without rotating" {
    const bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    const address = rom_base + 3;
    try std.testing.expectEqual(@as(u8, 0x44), bus.readData(u8, address));
    try std.testing.expectEqual(@as(u16, 0x4433), bus.readData(u16, address));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, address));
}
