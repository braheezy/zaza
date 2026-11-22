const api = @import("lib.zig");
pub const video = api.video;
pub const input = api.input;
pub const AudioCapture = api.AudioCapture;
pub const sample_rate = api.sample_rate;
pub const SaveMemory = api.SaveMemory;
pub const frame_period_ns = api.frame_period_ns;
pub const Bios = api.Bios;
pub const max_rom_size = api.max_rom_size;
pub const Options = api.Options;
pub const Emulator = api.Emulator;
pub const bundled_bios = api.bundled_bios;

test {
    _ = @import("machine_tests.zig");
}
