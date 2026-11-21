const std = @import("std");
const SaveMemory = @This();

pub const Kind = enum {
    none,
    sram,
    flash64,
    flash128,
    eeprom,
    eeprom512,
    eeprom8k,

    pub fn detect(rom: []const u8) Kind {
        const signatures = .{
            .{ "FLASH1M_V", .flash128 },
            .{ "FLASH512_V", .flash64 },
            .{ "FLASH_V", .flash64 },
            .{ "EEPROM_V", .eeprom },
            .{ "SRAM_F_V", .sram },
            .{ "SRAM_V", .sram },
        };
        inline for (signatures) |entry| {
            if (std.mem.find(u8, rom, entry[0]) != null) return entry[1];
        }
        return .none;
    }

    pub fn size(self: Kind) usize {
        return switch (self) {
            .none, .eeprom => 0,
            .sram => 32 * 1024,
            .flash64 => flash_bank_size,
            .flash128 => 2 * flash_bank_size,
            .eeprom512 => 512,
            .eeprom8k => 8 * 1024,
        };
    }

    fn isEeprom(self: Kind) bool {
        return switch (self) {
            .eeprom, .eeprom512, .eeprom8k => true,
            else => false,
        };
    }
};

const flash_bank_size = 64 * 1024;
const flash_sector_size = 4 * 1024;
const flash_unlock_first = 0x5555;
const flash_unlock_second = 0x2AAA;
const flash_sector_erase_cycles = 30_000;
const eeprom_write_cycles = 108_368;

const FlashErase = struct {
    offset: usize,
    size: usize,
    cycles_left: u64,
};

const Flash = struct {
    unlock: enum { idle, first, second } = .idle,
    command: enum { none, program, erase, bank } = .none,
    id_mode: bool = false,
    bank: u1 = 0,
    pending_erase: ?FlashErase = null,
};

const Eeprom = struct {
    // A DMA command carries at most 81 bits, MSB first.
    command: u128 = 0,
    block_offset: ?usize = null,
    read_bit: u7 = 0,
    busy_cycles: u64 = 0,
};

kind: Kind = .none,
storage: [2 * flash_bank_size]u8 = @splat(0xFF),
dirty: bool = false,
flash: Flash = .{},
eeprom: Eeprom = .{},

pub fn containsParallel(address: u32) bool {
    return address >= 0x0E00_0000 and address < 0x1000_0000;
}

pub fn containsEeprom(self: *const SaveMemory, rom_size: usize, address: u32) bool {
    if (!self.kind.isEeprom()) return false;
    const start: u32 = if (rom_size <= 16 * 1024 * 1024) 0x0D00_0000 else 0x0DFF_FF00;
    return address >= start and address < 0x0E00_0000;
}

pub fn bytes(self: *const SaveMemory) []const u8 {
    return self.storage[0..self.kind.size()];
}

pub fn load(self: *SaveMemory, data: []const u8) !void {
    const kind: Kind = if (self.kind == .eeprom) switch (data.len) {
        512 => .eeprom512,
        8192 => .eeprom8k,
        else => return error.InvalidSaveSize,
    } else self.kind;
    if (data.len == 0 or data.len != kind.size()) return error.InvalidSaveSize;
    @memcpy(self.storage[0..data.len], data);
    self.kind = kind;
    self.dirty = false;
    self.flash = .{};
    self.eeprom = .{};
}

pub fn readParallel(self: *const SaveMemory, address: u32) u8 {
    const offset: u16 = @truncate(address);
    return switch (self.kind) {
        .sram => self.storage[offset % Kind.sram.size()],
        .flash64, .flash128 => self.readFlash(offset),
        else => 0xFF,
    };
}

pub fn writeParallel(self: *SaveMemory, address: u32, value: u8) void {
    const offset: u16 = @truncate(address);
    switch (self.kind) {
        .sram => self.writeByte(offset % Kind.sram.size(), value),
        .flash64, .flash128 => self.writeFlash(offset, value),
        else => {},
    }
}

fn readFlash(self: *const SaveMemory, offset: u16) u8 {
    if (self.flash.id_mode) {
        // Model Macronix chips for both capacities.
        switch (offset) {
            0 => return 0xC2,
            1 => return if (self.kind == .flash128) 0x09 else 0x1C,
            else => {},
        }
    }
    const index = self.flashOffset(offset);
    if (self.flash.pending_erase) |operation| {
        // DQ7 reads low until erasing has restored the affected bytes to FF.
        if (index >= operation.offset and index < operation.offset + operation.size) return 0;
    }
    return self.storage[index];
}

fn writeFlash(self: *SaveMemory, offset: u16, value: u8) void {
    if (self.flash.pending_erase != null) {
        if (offset == flash_unlock_first and value == 0xF0) self.resetFlashCommand();
        return;
    }
    switch (self.flash.command) {
        .program => {
            const index = self.flashOffset(offset);
            self.writeByte(index, self.storage[index] & value);
            self.flash.command = .none;
            return;
        },
        .bank => {
            if (offset == 0 and value <= 1) self.flash.bank = @truncate(value);
            self.flash.command = .none;
            return;
        },
        .none, .erase => {},
    }

    if (value == 0xF0 and offset == flash_unlock_first) {
        self.resetFlashCommand();
        return;
    }
    switch (self.flash.unlock) {
        .idle => {
            if (offset == flash_unlock_first and value == 0xAA) self.flash.unlock = .first;
        },
        .first => {
            self.flash.unlock = if (offset == flash_unlock_second and value == 0x55)
                .second
            else
                .idle;
            if (self.flash.unlock == .idle) self.flash.command = .none;
        },
        .second => {
            self.flash.unlock = .idle;
            if (self.flash.command == .erase) {
                self.flash.command = .none;
                if (offset == flash_unlock_first and value == 0x10) {
                    self.startErase(0, self.kind.size());
                } else if (offset % flash_sector_size == 0 and value == 0x30) {
                    self.startErase(self.flashOffset(offset), flash_sector_size);
                }
            } else if (offset == flash_unlock_first and !self.flash.id_mode) {
                switch (value) {
                    0x80 => self.flash.command = .erase,
                    0x90 => self.flash.id_mode = true,
                    0xA0 => self.flash.command = .program,
                    0xB0 => if (self.kind == .flash128) {
                        self.flash.command = .bank;
                    },
                    else => {},
                }
            }
        },
    }
}

test "Flash chip IDs and programming honor the unlock sequence" {
    var save: SaveMemory = .{ .kind = .flash128 };
    save.writeParallel(0x0100, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), save.readParallel(0x0100));

    for ([_]u8{ 0x90, 0xF0, 0xA0, 0xA0 }) |command| {
        save.writeParallel(flash_unlock_first, 0xAA);
        save.writeParallel(flash_unlock_second, 0x55);
        save.writeParallel(flash_unlock_first, command);
        switch (command) {
            0x90 => {
                try std.testing.expectEqual(@as(u8, 0xC2), save.readParallel(0));
                try std.testing.expectEqual(@as(u8, 0x09), save.readParallel(1));
            },
            0xF0 => try std.testing.expectEqual(@as(u8, 0xFF), save.readParallel(0)),
            0xA0 => {
                const old = save.readParallel(0x0100);
                save.writeParallel(0x0100, if (old == 0xFF) 0x0F else 0xF0);
            },
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(u8, 0), save.readParallel(0x0100));

    for ([_]u8{ 0x80, 0x30 }) |command| {
        save.writeParallel(flash_unlock_first, 0xAA);
        save.writeParallel(flash_unlock_second, 0x55);
        save.writeParallel(if (command == 0x80) flash_unlock_first else 0, command);
    }
    try std.testing.expectEqual(@as(u8, 0), save.readParallel(0x0101));
    save.advance(flash_sector_erase_cycles - 1);
    try std.testing.expectEqual(@as(u8, 0), save.readParallel(0x0101));
    save.advance(1);
    try std.testing.expectEqual(@as(u8, 0xFF), save.readParallel(0x0100));
}

fn resetFlashCommand(self: *SaveMemory) void {
    self.flash.unlock = .idle;
    self.flash.command = .none;
    self.flash.id_mode = false;
    self.flash.pending_erase = null;
}

fn flashOffset(self: *const SaveMemory, offset: u16) usize {
    return @as(usize, self.flash.bank) * flash_bank_size + offset;
}

fn startErase(self: *SaveMemory, offset: usize, size: usize) void {
    // Scale the erase delay by the number of sectors as a chip timing approximation.
    self.flash.pending_erase = .{
        .offset = offset,
        .size = size,
        .cycles_left = flash_sector_erase_cycles * (size / flash_sector_size),
    };
}

fn writeByte(self: *SaveMemory, offset: usize, value: u8) void {
    if (self.storage[offset] == value) return;
    self.storage[offset] = value;
    self.dirty = true;
}

pub fn advance(self: *SaveMemory, cycles: u64) void {
    self.eeprom.busy_cycles -|= cycles;
    if (self.flash.pending_erase) |*operation| {
        operation.cycles_left -|= cycles;
        if (operation.cycles_left != 0) return;
        const data = self.storage[operation.offset..][0..operation.size];
        if (!std.mem.allEqual(u8, data, 0xFF)) {
            @memset(data, 0xFF);
            self.dirty = true;
        }
        self.flash.pending_erase = null;
    }
}

pub fn eepromReady(self: *const SaveMemory) u16 {
    return @intFromBool(self.eeprom.busy_cycles == 0);
}

pub fn beginEepromCommand(self: *SaveMemory) void {
    self.eeprom.command = 0;
}

pub fn shiftEepromCommand(self: *SaveMemory, value: u16) void {
    self.eeprom.command = (self.eeprom.command << 1) | (value & 1);
}

pub fn finishEepromCommand(self: *SaveMemory, count: u32) void {
    if (self.eeprom.busy_cycles != 0) return;
    const command = self.eeprom.command;
    if (command & 1 != 0) return;
    const received_kind: Kind = switch (count) {
        9, 73 => .eeprom512,
        17, 81 => .eeprom8k,
        else => return,
    };
    if (self.kind != .eeprom and self.kind != received_kind) return;
    const opcode = command >> @intCast(count - 2);
    const write = count >= 73;
    if (opcode != @as(u128, if (write) 2 else 3)) return;

    self.kind = received_kind;
    const address_shift: u7 = if (write) 65 else 1;
    const offset = (@as(usize, @truncate(command >> address_shift)) *% 8) % self.kind.size();
    if (!write) {
        self.eeprom.block_offset = offset;
        self.eeprom.read_bit = 0;
        return;
    }

    self.eeprom.block_offset = null;
    const data: u64 = @truncate(command >> 1);
    for (0..8) |index| {
        self.writeByte(offset + index, @truncate(data >> @intCast((7 - index) * 8)));
    }
    self.eeprom.busy_cycles = eeprom_write_cycles;
}

pub fn readEepromBit(self: *SaveMemory) u16 {
    const offset = self.eeprom.block_offset orelse return self.eepromReady();
    const index = self.eeprom.read_bit;
    self.eeprom.read_bit += 1;
    if (index < 4) return 0;
    const data_bit = index - 4;
    const value = self.storage[offset + data_bit / 8] >> @intCast(7 - data_bit % 8);
    if (data_bit == 63) self.eeprom.block_offset = null;
    return value & 1;
}
