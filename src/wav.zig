const std = @import("std");
const zaza = @import("libzaza");

pub fn header(data_bytes: u32) [44]u8 {
    var bytes: [44]u8 = undefined;
    bytes[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    bytes[8..16].* = "WAVEfmt ".*;
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little); // Linear PCM.
    std.mem.writeInt(u16, bytes[22..24], 2, .little);
    std.mem.writeInt(u32, bytes[24..28], zaza.sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], zaza.sample_rate * 4, .little);
    std.mem.writeInt(u16, bytes[32..34], 4, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    bytes[36..40].* = "data".*;
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    return bytes;
}
