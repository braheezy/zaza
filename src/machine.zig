const Cpu = @import("cpu.zig");
const Bus = @import("bus.zig");
const Machine = @This();

cpu: Cpu,
bus: Bus,

// Start directly at the cartridge entry point without running the BIOS.
pub fn initCartridge(self: *Machine, rom: []const u8) void {
    self.* = .{
        .cpu = .{ .instruction_address = Bus.rom_base },
        .bus = .{ .rom = rom },
    };
    self.cpu.refillArmPipeline(&self.bus);
}

pub fn step(self: *Machine) !void {
    try self.cpu.step(&self.bus);
}
