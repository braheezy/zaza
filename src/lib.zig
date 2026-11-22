//! Caller-owned GBA emulation. All mutable state belongs to one Emulator.
const Machine = @import("machine.zig");
const std = @import("std");
pub const video = @import("video.zig");
pub const input = @import("input.zig");
pub const AudioCapture = @import("audio.zig").Capture;
pub const sample_rate = @import("audio.zig").sample_rate;
pub const SaveMemory = @import("save_memory.zig");
pub const frame_period_ns = @import("timing.zig").cycles_per_frame * std.time.ns_per_s / (1 << 24);
pub const Bios = [@import("bus.zig").bios_size_bytes]u8;
pub const max_rom_size = 32 * 1024 * 1024;

pub const Options = struct {
    bios: *const Bios = bundled_bios,
    boot: enum { cartridge, bios } = .cartridge,
};

pub const Emulator = struct {
    machine: Machine,

    /// Borrows both images for the lifetime of this emulator and its checkpoints.
    pub fn init(self: *Emulator, rom: []const u8, options: Options) !void {
        if (rom.len < 8) return error.RomTooShort;
        if (rom.len > max_rom_size) return error.RomTooLarge;
        switch (options.boot) {
            .cartridge => self.machine.initCartridgeWithBios(rom, options.bios),
            .bios => self.machine.initBios(rom, options.bios),
        }
    }

    pub fn runFrame(self: *Emulator, buttons: input.Buttons) !void {
        try self.machine.runFrame(buttons);
        if (self.machine.bus.audio.capture) |sink| if (sink.failure) |err| return err;
    }

    pub fn snapshotFrame(self: *const Emulator, out: *video.Frame) !void {
        try self.machine.snapshotFrame(out);
    }

    pub fn stepTimed(self: *Emulator) !void {
        try self.machine.stepTimed();
    }

    pub fn snapshotBitmap(self: *const Emulator, out: *video.Frame) !void {
        try self.machine.snapshotBitmap(out);
    }

    pub fn instructionAddress(self: *const Emulator) u32 {
        return self.machine.cpu.instruction_address;
    }

    pub fn setAudioCapture(self: *Emulator, sink: ?*AudioCapture) void {
        self.machine.bus.audio.capture = sink;
    }

    pub fn saveMemory(self: *Emulator) *SaveMemory {
        return &self.machine.bus.save;
    }

    pub const Checkpoint = struct { state: Machine.Checkpoint };

    pub fn checkpoint(self: *const Emulator, out: *Checkpoint) void {
        self.machine.checkpoint(&out.state);
    }

    pub fn restore(self: *Emulator, saved: *const Checkpoint) void {
        saved.state.restore(&self.machine, self.machine.bus.audio.capture);
    }
};

pub const bundled_bios = @embedFile("emibios");
comptime {
    @setEvalBranchQuota(2_000_000);
    if (bundled_bios.len != @sizeOf(Bios)) @compileError("Invalid bundled BIOS size");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bundled_bios, &digest, .{});
    var expected_buffer: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(&expected_buffer, "95e6c8a6c236ed8e2629bdb60bc75791434c4f08ca69ad2305e30ca3f3c29d1b") catch unreachable;
    if (!std.mem.eql(u8, &digest, expected)) @compileError("Bundled BIOS checksum mismatch");
}
