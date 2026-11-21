const std = @import("std");
const Serial = @This();

pub const base: u32 = 0x0400_0120;
// Register storage only. Link transfers and pin behavior are not modeled yet.
registers: [0x16]u8 = @splat(0),
joy_control: u8 = 0,
joy_status: u8 = 0,
joy_receive: [4]u8 = @splat(0),
joy_transmit: [4]u8 = @splat(0),

pub const joycnt_address: u32 = 0x0400_0140;
const joy_receive_address: u32 = 0x0400_0150;
const joy_transmit_address: u32 = 0x0400_0154;
const joystat_address: u32 = 0x0400_0158;
const joy_irq_enable: u8 = 1 << 6;
const joy_event_flags: u8 = 0x07;
const joy_transmit_pending: u8 = 1 << 1;
const joy_receive_pending: u8 = 1 << 3;
const joy_status_writable: u8 = 0x30;

pub fn contains(address: u32) bool {
    return switch (address) {
        base...base + 0xB, base + 0x14...base + 0x15 => true,
        joycnt_address...joystat_address + 3 => true,
        else => false,
    };
}

pub fn read(self: *Serial, comptime T: type, address: u32) T {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    std.debug.assert(contains(address));
    var value: T = 0;
    for (0..@sizeOf(T)) |index| {
        const byte_address = address + @as(u32, @intCast(index));
        // A word access to RCNT includes an unused upper halfword.
        if (contains(byte_address)) {
            const byte = self.readByte(byte_address);
            value |= @as(T, byte) << @intCast(index * 8);
        }
    }
    return value;
}

pub fn write(self: *Serial, comptime T: type, address: u32, value: T) void {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    std.debug.assert(contains(address));
    for (0..@sizeOf(T)) |index| {
        const byte_address = address + @as(u32, @intCast(index));
        if (contains(byte_address)) {
            const byte: u8 = @truncate(value >> @intCast(index * 8));
            if (byte_address == base + 8 and byte & 0x80 != 0) {
                @panic("serial transfers are not modeled");
            }
            self.writeByte(byte_address, byte);
        }
    }
    // Reserved control bits do not retain writes (GBATEK SIO register map).
    self.registers[9] &= 0x7F;
    self.registers[0x15] &= 0xC1;
}

fn readByte(self: *Serial, address: u32) u8 {
    if (address < joycnt_address) return self.registers[address - base];
    return switch (address) {
        joycnt_address => self.joy_control,
        joy_receive_address...joy_receive_address + 3 => result: {
            self.joy_status &= ~joy_receive_pending;
            break :result self.joy_receive[address - joy_receive_address];
        },
        joy_transmit_address...joy_transmit_address + 3 => self.joy_transmit[address - joy_transmit_address],
        joystat_address => self.joy_status,
        // BIOS word accesses include unused lanes. Open-bus reads remain unmodeled.
        else => 0,
    };
}

fn writeByte(self: *Serial, address: u32, byte: u8) void {
    if (address < joycnt_address) {
        self.registers[address - base] = byte;
        return;
    }
    switch (address) {
        joycnt_address => {
            // Software can acknowledge an event but only the link can raise it.
            const pending = self.joy_control & joy_event_flags & ~byte;
            self.joy_control = pending | (byte & joy_irq_enable);
        },
        joy_receive_address...joy_receive_address + 3 => self.joy_receive[address - joy_receive_address] = byte,
        joy_transmit_address...joy_transmit_address + 3 => {
            self.joy_transmit[address - joy_transmit_address] = byte;
            self.joy_status |= joy_transmit_pending;
        },
        joystat_address => {
            self.joy_status = (self.joy_status & ~joy_status_writable) | (byte & joy_status_writable);
        },
        else => {}, // Unused bytes have no write side effects.
    }
}

test "serial byte writes preserve adjacent data and word accesses are little endian" {
    // BIOS uses byte stores even for registers also accessible as halfwords.
    var serial: Serial = .{};
    serial.write(u32, base, 0x4433_2211);
    serial.write(u8, base + 1, 0xAA);
    try std.testing.expectEqual(@as(u32, 0x4433_AA11), serial.read(u32, base));
    serial.write(u16, base + 8, 0);
    serial.write(u32, base + 0x14, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xC1FF), serial.read(u32, base + 0x14));
    try std.testing.expect(!contains(0x0400_0130));
    try std.testing.expect(!contains(base + 0xC));
}

test "JoyBus control writes acknowledge only selected events" {
    var serial: Serial = .{ .joy_control = 0x47 };
    serial.write(u32, joycnt_address, 0xFFFF_FF42);
    try std.testing.expectEqual(@as(u32, 0x45), serial.read(u32, joycnt_address));
    serial.write(u8, joycnt_address + 1, 0xFF);
    try std.testing.expectEqual(@as(u16, 0x45), serial.read(u16, joycnt_address));
    serial.write(u8, joycnt_address, 0x07);
    try std.testing.expectEqual(@as(u8, 0), serial.read(u8, joycnt_address));
}

test "JoyBus data accesses update local status without creating link events" {
    var serial: Serial = .{ .joy_status = joy_receive_pending };
    serial.write(u32, joy_receive_address, 0x1234_5678);
    serial.write(u32, joy_transmit_address, 0xABCD_EF12);
    serial.write(u32, joystat_address, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x3A), serial.read(u32, joystat_address));
    try std.testing.expectEqual(@as(u32, 0xABCD_EF12), serial.read(u32, joy_transmit_address));
    try std.testing.expectEqual(@as(u16, 0x1234), serial.read(u16, joy_receive_address + 2));
    try std.testing.expectEqual(@as(u8, 0x32), serial.read(u8, joystat_address));
    try std.testing.expectEqual(@as(u32, 0), serial.read(u32, joycnt_address));
}
