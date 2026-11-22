const std = @import("std");
const video = @import("video.zig");
const DisplayRegisters = @import("display_registers.zig");

const background_vram_size = 64 * 1024;
const object_vram_size = 32 * 1024;
const object_layer = 4;
const backdrop_layer = 5;

pub const VerticalWindows = struct {
    active: [2]bool = @splat(false),

    pub fn beginLine(self: *VerticalWindows, line: usize, registers: *const DisplayRegisters) void {
        for (&self.active, 0..) |*active, index| {
            const limits = registers.stored(0x0400_0044 + @as(u32, @intCast(index * 2)));
            // VCOUNT visits 0..227. An unreachable end leaves the window open across frames.
            if (line == limits & 0xFF) {
                active.* = false;
            } else if (line == limits >> 8) {
                active.* = true;
            }
        }
    }
};

pub const Display = struct {
    control: u16,
    bg_pixel_mask: ?*const [video.width]u8 = null,
    green_swap: bool,
    vertical_windows: VerticalWindows,
    registers: *const DisplayRegisters,
    vram: *const [background_vram_size + object_vram_size]u8,
    palette: *const [1024]u8,
    oam: *const [1024]u8,

    pub fn renderLine(self: Display, y: usize, row: *[video.width]video.Rgb) void {
        if (self.control & (1 << 7) != 0) {
            row.* = @splat(video.decodeColor(0x7FFF));
            return;
        }

        const mosaic = self.registers.stored(0x0400_004C);
        var backgrounds: [4]?Background = @splat(null);
        const mode = self.control & 7;
        const text_count: usize = switch (mode) {
            0 => 4,
            1 => 2,
            else => 0,
        };
        for (backgrounds[0..text_count], 0..) |*background, index| {
            if (self.control & (@as(u16, 0x100) << @intCast(index)) != 0) {
                background.* = self.backgroundForLine(index, y, mosaic);
            }
        }
        var affine: [2]?AffineLine = @splat(null);
        for (&affine, 0..) |*layer, i| {
            if (mode == 0 or (i == 1 and mode != 2)) continue;
            if (self.control & (@as(u16, 0x400) << @intCast(i)) != 0) {
                layer.* = AffineLine.init(self, i, y, mosaic);
            }
        }

        var objects: [video.width]ObjectPixel = @splat(.{});
        if (self.control & (1 << 12) != 0) self.drawObjects(y, mosaic, &objects);
        const effect = Effects.init(self.registers);
        const backdrop: Pixel = .{ .color = readHalf(self.palette, 0), .rank = 20, .layer = backdrop_layer };
        for (row, objects, 0..) |*output, object, x| {
            var mask = self.windowMask(x, object.window);
            if (self.bg_pixel_mask) |pixels| mask &= 0xF0 | pixels[x];
            var layers: Layers = .{ .front = backdrop, .behind = backdrop };
            for (backgrounds[0..text_count], 0..) |maybe_background, index| {
                if (mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
                const bg = maybe_background orelse continue;
                const color = self.backgroundPixel(bg, x) orelse continue;
                layers.insert(.{ .color = color, .rank = bg.rank, .layer = @intCast(index) });
            }
            for (affine, 0..) |maybe_bg, i| {
                const bg = maybe_bg orelse continue;
                const index: u3 = @intCast(2 + i);
                if (mask & (@as(u8, 1) << index) == 0) continue;
                if (bg.pixel(self, x)) |color| layers.insert(.{ .color = color, .layer = index, .rank = bg.rank });
            }
            if (mask & (1 << object_layer) != 0) {
                if (object.pixel) |pixel| layers.insert(pixel);
            }
            const color = if (mask & (1 << 5) != 0) effect.apply(layers) else layers.front.color;
            output.* = video.decodeColor(color);
        }
        if (self.green_swap) video.swapGreen(row);
    }

    fn backgroundForLine(self: Display, index: usize, y: usize, mosaic: u16) Background {
        const offset: u32 = @intCast(index * 2);
        const control = self.registers.stored(0x0400_0008 + offset);
        const use_mosaic = control & (1 << 6) != 0;
        const horizontal = self.registers.stored(0x0400_0010 + offset * 2);
        const vertical = self.registers.stored(0x0400_0012 + offset * 2);
        const step_y = mosaicSize(mosaic, 4);
        return .{
            .character_base = @as(usize, (control >> 2) & 3) * 0x4000,
            .screen_base = @as(usize, (control >> 8) & 31) * 0x800,
            .wide = control & (1 << 14) != 0,
            .tall = control & (1 << 15) != 0,
            .eight_bit = control & (1 << 7) != 0,
            .scroll_x = horizontal,
            .sample_y = (if (use_mosaic) y - y % step_y else y) + vertical,
            .mosaic_width = if (use_mosaic) mosaicSize(mosaic, 0) else 1,
            .rank = @intCast((control & 3) * 5 + 1 + index),
        };
    }

    fn backgroundPixel(self: Display, bg: Background, screen_x: usize) ?u16 {
        const x = (screen_x - screen_x % bg.mosaic_width + bg.scroll_x) & bg.xMask();
        const y = bg.sample_y & bg.yMask();
        const block = (x >> 8) + (y >> 8) * @as(usize, if (bg.wide) 2 else 1);
        const tile = ((y >> 3) & 31) * 32 + ((x >> 3) & 31);
        const entry_offset = (bg.screen_base + block * 0x800 + tile * 2) % background_vram_size;
        const entry = readHalf(self.vram, entry_offset);
        const tile_x = if (entry & (1 << 10) != 0) 7 - (x & 7) else x & 7;
        const tile_y = if (entry & (1 << 11) != 0) 7 - (y & 7) else y & 7;
        const tile_size: usize = if (bg.eight_bit) 64 else 32;
        const tile_base = bg.character_base + @as(usize, entry & 0x03FF) * tile_size;
        // Use single-BG open-bus behavior when the character fetch exceeds BG VRAM.
        const index: u8 = if (tile_base < background_vram_size)
            tilePixel(self.vram, tile_base, tile_x, tile_y, bg.eight_bit)
        else if (bg.eight_bit)
            @truncate(entry >> @intCast((x & 1) * 8))
        else
            @intCast((entry >> @intCast((x & 3) * 4)) & 15);
        if (index == 0) return null;
        const bank: usize = if (bg.eight_bit) 0 else (entry >> 12) * 16;
        return readHalf(self.palette, (bank + index) * 2);
    }

    fn windowMask(self: Display, x: usize, object_window: bool) u8 {
        if (self.control & 0xE000 == 0) return 0x3F;
        for (0..2) |index| {
            if (self.control & (@as(u16, 0x2000) << @intCast(index)) == 0) continue;
            const offset: u32 = @intCast(index * 2);
            const horizontal = self.registers.stored(0x0400_0040 + offset);
            if (self.vertical_windows.active[index] and insideWindow(x, horizontal)) {
                return @truncate(self.registers.stored(0x0400_0048) >> @intCast(index * 8));
            }
        }
        const outside = self.registers.stored(0x0400_004A);
        return @truncate(if (self.control & 0x8000 != 0 and object_window) outside >> 8 else outside);
    }

    fn drawObjects(self: Display, y: usize, mosaic: u16, row: *[video.width]ObjectPixel) void {
        var cycles: usize = if (self.control & (1 << 5) != 0) 954 else 1210;
        for (0..128) |index| {
            if (cycles == 0) break;
            const attributes = Object.read(self.oam, index) orelse continue;
            const relative_y = (y -% @as(usize, @as(u8, @truncate(attributes.first)))) & 255;
            if (relative_y >= attributes.canvas_height) continue;

            const overhead: usize = if (attributes.matrix != null) 10 else 0;
            const pixel_cycles: usize = if (attributes.matrix != null) 2 else 1;
            cycles -|= overhead;
            const pixels = @min(attributes.canvas_width, cycles / pixel_cycles);
            cycles -|= attributes.canvas_width * pixel_cycles;
            for (0..pixels) |relative_x| {
                const x = (attributes.x + relative_x) & 511;
                if (x >= video.width) continue;
                const palette_index = self.objectPixel(attributes, relative_x, relative_y, mosaic) orelse continue;
                if (attributes.mode == 2) {
                    row[x].window = true;
                    continue;
                }
                if (row[x].pixel) |current| {
                    if (current.rank <= attributes.rank) continue;
                }
                row[x].pixel = .{
                    .color = readHalf(self.palette, 512 + palette_index * 2),
                    .rank = attributes.rank,
                    .layer = object_layer,
                    .semitransparent = attributes.mode == 1,
                };
            }
        }
    }

    fn objectPixel(self: Display, object: Object, x: usize, y: usize, mosaic: u16) ?usize {
        const use_mosaic = object.first & (1 << 12) != 0;
        const sample_x = if (use_mosaic) x - x % mosaicSize(mosaic, 8) else x;
        const sample_y = if (use_mosaic) y - y % mosaicSize(mosaic, 12) else y;
        const texel = object.texel(sample_x, sample_y) orelse return null;
        const tile_units: usize = if (object.eight_bit) 2 else 1;
        const one_dimensional = self.control & (1 << 6) != 0;
        const stride = if (one_dimensional) object.width / 8 * tile_units else 32;
        var tile: usize = object.third & 0x03FF;
        if (object.eight_bit and !one_dimensional) tile &= ~@as(usize, 1);
        tile += texel.y / 8 * stride + texel.x / 8 * tile_units;
        // A 256-color tile spans two 32-byte character units, including at wraparound.
        const tile_y = texel.y & 7;
        if (object.eight_bit) tile += tile_y / 4;
        tile &= 0x3FF;
        if (self.control & 7 >= 3 and tile < 512) return null;
        const tile_base = background_vram_size + tile * 32;
        const index = tilePixel(self.vram, tile_base, texel.x & 7, if (object.eight_bit) tile_y & 3 else tile_y, object.eight_bit);
        if (index == 0) return null;
        const bank: usize = if (object.eight_bit) 0 else (object.third >> 12) * 16;
        return bank + index;
    }
};

const AffineLine = struct {
    start_x: i32,
    start_y: i32,
    dx: i16,
    dy: i16,
    mosaic_width: usize,
    rank: u5,

    control: u16,

    fn init(display: Display, index: usize, y: usize, mosaic: u16) AffineLine {
        const regs = display.registers;
        const offset: u32 = @intCast(index * 16);
        const control = regs.stored(0x0400_000C + @as(u32, @intCast(index * 2)));
        const use_mosaic = control & (1 << 6) != 0;
        const line: i32 = @intCast(if (use_mosaic) y - y % mosaicSize(mosaic, 4) else y);
        const pb: i16 = @bitCast(regs.stored(0x0400_0022 + offset));
        const pd: i16 = @bitCast(regs.stored(0x0400_0026 + offset));
        return .{
            .start_x = regs.affineReference(0x0400_0028 + offset) + pb * line,
            .start_y = regs.affineReference(0x0400_002C + offset) + pd * line,
            .dx = @bitCast(regs.stored(0x0400_0020 + offset)),
            .dy = @bitCast(regs.stored(0x0400_0024 + offset)),
            .mosaic_width = if (use_mosaic) mosaicSize(mosaic, 0) else 1,
            .rank = @intCast((control & 3) * 5 + 3 + index),
            .control = control,
        };
    }

    fn pixel(self: AffineLine, display: Display, x: usize) ?u16 {
        const screen_x: i32 = @intCast(x - x % self.mosaic_width);
        const sx = (self.start_x + self.dx * screen_x) >> 8;
        const sy = (self.start_y + self.dy * screen_x) >> 8;
        const mode = display.control & 7;
        if (mode <= 2) {
            const size: usize = @as(usize, 128) << @intCast(self.control >> 14);
            if (self.control & (1 << 13) == 0 and (sx < 0 or sy < 0 or sx >= size or sy >= size)) return null;
            const tx = @as(u32, @bitCast(sx)) & (size - 1);
            const ty = @as(u32, @bitCast(sy)) & (size - 1);
            const screen_base = @as(usize, (self.control >> 8) & 31) * 0x800;
            const tile = display.vram[(screen_base + (ty / 8) * (size / 8) + tx / 8) % background_vram_size];
            const char_base = @as(usize, (self.control >> 2) & 3) * 0x4000;
            const index = display.vram[char_base + @as(usize, tile) * 64 + (ty % 8) * 8 + tx % 8];
            return if (index == 0) null else readHalf(display.palette, @as(usize, index) * 2);
        }
        const width: usize = if (mode == 5) 160 else video.width;
        const height: usize = if (mode == 5) 128 else video.height;
        if (sx < 0 or sy < 0 or sx >= width or sy >= height) return null;
        const offset = @as(usize, @intCast(sy)) * width + @as(usize, @intCast(sx));
        const page: usize = if (mode != 3 and display.control & (1 << 4) != 0) 0xA000 else 0;
        if (mode == 4) {
            const index = display.vram[page + offset];
            return if (index == 0) null else readHalf(display.palette, @as(usize, index) * 2);
        }
        return readHalf(display.vram, page + offset * 2);
    }
};

const Background = struct {
    character_base: usize,
    screen_base: usize,
    wide: bool,
    tall: bool,
    eight_bit: bool,
    scroll_x: usize,
    sample_y: usize,
    mosaic_width: usize,
    rank: u5,

    fn xMask(self: Background) usize {
        return if (self.wide) 511 else 255;
    }

    fn yMask(self: Background) usize {
        return if (self.tall) 511 else 255;
    }
};

const Object = struct {
    first: u16,
    second: u16,
    third: u16,
    x: usize,
    width: usize,
    height: usize,
    canvas_width: usize,
    canvas_height: usize,
    rank: u5,
    matrix: ?[4]i16,
    eight_bit: bool,
    mode: u2,

    fn read(oam: []const u8, index: usize) ?Object {
        const first = readHalf(oam, index * 8);
        const second = readHalf(oam, index * 8 + 2);
        const third = readHalf(oam, index * 8 + 4);
        const affine = first & (1 << 8) != 0;
        const double_or_hidden = first & (1 << 9) != 0;
        const mode: u2 = @truncate(first >> 10);
        const shape = first >> 14;
        if ((!affine and double_or_hidden) or shape == 3 or mode == 3) return null;
        const sizes = [3][4][2]usize{
            .{ .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 } },
            .{ .{ 16, 8 }, .{ 32, 8 }, .{ 32, 16 }, .{ 64, 32 } },
            .{ .{ 8, 16 }, .{ 8, 32 }, .{ 16, 32 }, .{ 32, 64 } },
        };
        const width, const height = sizes[shape][second >> 14];
        const scale: usize = if (double_or_hidden) 2 else 1;
        const matrix_offset = @as(usize, (second >> 9) & 31) * 32;
        return .{
            .first = first,
            .second = second,
            .third = third,
            .x = second & 511,
            .width = width,
            .height = height,
            .canvas_width = width * scale,
            .canvas_height = height * scale,
            .rank = @intCast(((third >> 10) & 3) * 5),
            .matrix = if (affine) .{
                @bitCast(readHalf(oam, matrix_offset + 6)),
                @bitCast(readHalf(oam, matrix_offset + 14)),
                @bitCast(readHalf(oam, matrix_offset + 22)),
                @bitCast(readHalf(oam, matrix_offset + 30)),
            } else null,
            .eight_bit = first & (1 << 13) != 0,
            .mode = mode,
        };
    }

    fn texel(self: Object, x: usize, y: usize) ?struct { x: usize, y: usize } {
        const matrix = self.matrix orelse return .{
            .x = if (self.second & (1 << 12) != 0) self.width - 1 - x else x,
            .y = if (self.second & (1 << 13) != 0) self.height - 1 - y else y,
        };
        const pa, const pb, const pc, const pd = matrix;
        const dx = @as(i32, @intCast(x)) - @as(i32, @intCast(self.canvas_width / 2));
        const dy = @as(i32, @intCast(y)) - @as(i32, @intCast(self.canvas_height / 2));
        const local_x = ((pa * dx + pb * dy) >> 8) + @as(i32, @intCast(self.width / 2));
        const local_y = ((pc * dx + pd * dy) >> 8) + @as(i32, @intCast(self.height / 2));
        if (local_x < 0 or local_y < 0 or local_x >= self.width or local_y >= self.height) return null;
        return .{ .x = @intCast(local_x), .y = @intCast(local_y) };
    }
};

const ObjectPixel = struct {
    pixel: ?Pixel = null,
    window: bool = false,
};

const Pixel = struct {
    color: u16,
    rank: u5,
    layer: u3,
    semitransparent: bool = false,
};

const Layers = struct {
    front: Pixel,
    behind: Pixel,

    fn insert(self: *Layers, pixel: Pixel) void {
        if (pixel.rank < self.front.rank) {
            self.behind = self.front;
            self.front = pixel;
        } else if (pixel.rank < self.behind.rank) {
            self.behind = pixel;
        }
    }
};

const Effects = struct {
    control: u16,
    first: u16,
    second: u16,
    brightness: u16,

    fn init(registers: *const DisplayRegisters) Effects {
        const alpha = registers.stored(0x0400_0052);
        return .{
            .control = registers.stored(0x0400_0050),
            .first = @min(alpha & 31, 16),
            .second = @min((alpha >> 8) & 31, 16),
            .brightness = @min(registers.stored(0x0400_0054) & 31, 16),
        };
    }

    fn apply(self: Effects, layers: Layers) u16 {
        const top = layers.front;
        const below = layers.behind;
        const first_target = self.control & (@as(u16, 1) << top.layer) != 0;
        const second_target = self.control & (@as(u16, 0x100) << below.layer) != 0;
        const mode: u2 = @truncate(self.control >> 6);
        const alpha = top.rank != below.rank and second_target and
            (top.semitransparent or (mode == 1 and first_target));
        if (!alpha and (!first_target or mode < 2)) return top.color;
        var result: u16 = 0;
        for ([_]u4{ 0, 5, 10 }) |shift| {
            const channel = (top.color >> shift) & 31;
            const value = if (alpha) blk: {
                const other = (below.color >> shift) & 31;
                break :blk @min(31, (channel * self.first + other * self.second) >> 4);
            } else if (mode == 2)
                channel + (((31 - channel) * self.brightness) >> 4)
            else
                channel - ((channel * self.brightness) >> 4);
            result |= value << shift;
        }
        return result;
    }
};

fn readHalf(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn mosaicSize(register: u16, shift: u4) usize {
    return @as(usize, (register >> shift) & 15) + 1;
}

fn insideWindow(position: usize, limits: u16) bool {
    const start = limits >> 8;
    const end = limits & 255;
    if (start <= end) return position >= start and position < end;
    return position >= start or position < end;
}

fn tilePixel(vram: []const u8, base: usize, x: usize, y: usize, eight_bit: bool) u8 {
    if (eight_bit) return vram[base + y * 8 + x];
    const packed_pixels = vram[base + y * 4 + x / 2];
    return (packed_pixels >> @intCast((x & 1) * 4)) & 15;
}
