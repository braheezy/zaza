// A fast-boot ARM cartridge for deterministic Direct Sound checks.
const std = @import("std");
const source_offset = 0x200;
const right_source_offset = source_offset + 1024;
pub const rom = buildRom();

fn buildRom() [right_source_offset + 512]u8 {
    @setEvalBranchQuota(10000);
    var bytes = [_]u8{0} ** (right_source_offset + 512);
    // Stream address/value pairs to MMIO, then branch to self.
    const program = [_]u32{
        0xE28F0010, // ADD r0, pc, #16 (table follows the six instructions)
        0xE8B00006, // LDMIA r0!, {r1,r2}
        0xE3510000, // CMP r1, #0
        0x15812000, // STRNE r2, [r1]
        0x1AFFFFFB, // BNE to LDMIA
        0xEAFFFFFE, // B .
    };
    for (program, 0..) |word, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, .little);
    var cursor: usize = program.len * 4;
    pair(&bytes, &cursor, 0x04000084, 0x80); // Sound master enable.
    pair(&bytes, &cursor, 0x04000080, 0x520C0000); // A left/timer 0, B right/timer 1.
    for (0..8) |word| {
        const sample: u32 = @intCast(word * 4 + 1);
        pair(&bytes, &cursor, 0x040000A0, 0x03020100 + sample * 0x01010101);
        pair(&bytes, &cursor, 0x040000A4, 0xFCFDFEFF - sample * 0x01010101); // Descending signed ramp.
    }
    pair(&bytes, &cursor, 0x040000BC, 0x08000000 + source_offset); // DMA1 source
    pair(&bytes, &cursor, 0x040000C0, 0x040000A0); // FIFO A destination
    pair(&bytes, &cursor, 0x040000C4, 0xB2000001); // Repeat, special, deliberately count=1.
    pair(&bytes, &cursor, 0x040000C8, 0x08000000 + right_source_offset); // DMA2 source
    pair(&bytes, &cursor, 0x040000CC, 0x040000A4); // FIFO B destination
    pair(&bytes, &cursor, 0x040000D0, 0xB2000001);
    pair(&bytes, &cursor, 0x04000100, 0x0080FE00); // One sample every 512 clocks.
    pair(&bytes, &cursor, 0x04000104, 0x0080FC00); // Every 1024 clocks.
    // Stall the CPU long enough for both sound channels to need multiple refills.
    pair(&bytes, &cursor, 0x040000D4, 0x02000000);
    pair(&bytes, &cursor, 0x040000D8, 0x06000000);
    pair(&bytes, &cursor, 0x040000DC, 0x84001000);
    // Zero-initialized table terminator. The ramp continues into the DMA source.
    for (bytes[source_offset..right_source_offset], 0..) |*byte, i| byte.* = @truncate(i + 33);
    for (bytes[right_source_offset..], 0..) |*byte, i| byte.* = 0 -% @as(u8, @truncate(i + 34));
    return bytes;
}

fn pair(bytes: []u8, cursor: *usize, address: u32, value: u32) void {
    std.mem.writeInt(u32, bytes[cursor.*..][0..4], address, .little);
    std.mem.writeInt(u32, bytes[cursor.* + 4 ..][0..4], value, .little);
    cursor.* += 8;
}
