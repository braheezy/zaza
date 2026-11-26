const std = @import("std");
const video = @import("video.zig");
const DisplayRegisters = @import("display_registers.zig");

const background_vram_size = 64 * 1024;
const object_vram_size = 32 * 1024;
// The final screen-entry fetch can outlive the last tile-data fetch.
const text_entry_cutoff = 1007;
const text_data_cutoff = 1004;
const object_layer = 4;
const backdrop_layer = 5;
const backdrop_rank = 20;

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

    pub fn renderLine(self: Display, y: usize, row: *[video.width]video.Rgb, latch: *u16) void {
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
        var text_pixels: [4][video.width]u8 = undefined;
        if (text_count != 0 and self.control & 0x0F00 != 0) {
            self.fetchTextLine(backgrounds[0..text_count], &text_pixels, latch);
        }
        var affine: [2]?AffineLine = @splat(null);
        for (&affine, 0..) |*layer, i| {
            if (mode == 0 or (i == 1 and mode != 2)) continue;
            if (self.control & (@as(u16, 0x400) << @intCast(i)) != 0) {
                layer.* = AffineLine.init(self, i, y, mosaic);
            }
        }

        const effect = Effects.init(self.registers);
        const front_only = self.canComposeFrontOnly(effect);
        var pixels: [video.width]PalettePixel = undefined;
        const bitmap_row = mode == 4 and front_only and self.fetchMode4Row(affine[0], &pixels);
        if (!bitmap_row) {
            pixels = @splat(.{});
            if (front_only) {
                for (backgrounds[0..text_count], 0..) |layer, i| {
                    if (layer) |bg| composeTextRow(&pixels, &text_pixels[i], bg);
                }
            }
        }
        if (self.control & (1 << 12) != 0) self.drawObjects(y, mosaic, &pixels);

        if (front_only) {
            if (bitmap_row or (affine[0] == null and affine[1] == null)) {
                for (row, pixels) |*output, pixel| {
                    output.* = video.decodeColor(pixel.color(self.palette));
                }
            } else {
                self.composeAffineRow(row, &pixels, affine);
            }
        } else {
            const backdrop: Pixel = .{
                .color = readHalf(self.palette, 0),
                .rank = backdrop_rank,
                .layer = backdrop_layer,
            };
            self.composeEffects(row, backgrounds[0..text_count], &text_pixels, affine, &pixels, backdrop, effect);
        }
        if (self.green_swap) video.swapGreen(row);
    }

    // Text backgrounds and sprites share a palette address space. Carry the winning
    // index through both passes so each output pixel needs just one palette lookup.
    fn composeTextRow(
        pixels: *[video.width]PalettePixel,
        indices: *const [video.width]u8,
        bg: Background,
    ) void {
        if (bg.mosaic_width == 1) {
            // Before sprites are drawn the high bits contain only the BG rank.
            // Ranks are distinct across layers, so the smaller packed pixel wins.
            const lanes = 8;
            const Words = @Vector(lanes, u16);
            const rank: Words = @splat(@as(u16, @bitCast(PalettePixel{ .rank = bg.rank })));
            const backdrop: Words = @splat(@as(u16, @bitCast(PalettePixel{})));
            for (0..@divExact(video.width, lanes)) |group| {
                const x = group * lanes;
                const bytes: @Vector(lanes, u8) = indices[x..][0..lanes].*;
                const index: Words = bytes;
                const transparent = index == @as(Words, @splat(0));
                const candidates = @select(u16, transparent, backdrop, rank | index);
                const previous: Words = @bitCast(pixels[x..][0..lanes].*);
                pixels[x..][0..lanes].* = @bitCast(@min(previous, candidates));
            }
        } else {
            var x: usize = 0;
            while (x < video.width) : (x += bg.mosaic_width) {
                const index = indices[x];
                if (index == 0) continue;
                for (pixels[x..@min(video.width, x + bg.mosaic_width)]) |*pixel| {
                    if (bg.rank < pixel.rank) pixel.* = .{ .index = index, .rank = bg.rank };
                }
            }
        }
    }

    fn composeAffineRow(
        self: Display,
        row: *[video.width]video.Rgb,
        pixels: *const [video.width]PalettePixel,
        affine: [2]?AffineLine,
    ) void {
        for (row, pixels, 0..) |*output, pixel, x| {
            var rank = pixel.rank;
            var color = pixel.color(self.palette);
            for (affine) |layer| {
                const bg = layer orelse continue;
                if (bg.rank >= rank) continue;
                color = bg.pixel(self, x) orelse continue;
                rank = bg.rank;
            }
            output.* = video.decodeColor(color);
        }
    }

    // A horizontal affine span samples a single palette-indexed row. Check both
    // ends once so negative steps and fractional scaling use the same inner loop.
    fn fetchMode4Row(self: Display, background: ?AffineLine, pixels: *[video.width]PalettePixel) bool {
        const bg = background orelse {
            pixels.* = @splat(.{});
            return true;
        };
        if (bg.dy != 0 or bg.mosaic_width != 1) return false;
        const sy = bg.start_y >> 8;
        const last_x = bg.start_x + @as(i32, bg.dx) * @as(i32, video.width - 1);
        if (sy < 0 or sy >= video.height or @min(bg.start_x, last_x) < 0 or
            @max(bg.start_x, last_x) >= video.width << 8) return false;

        const page: usize = if (self.control & (1 << 4) != 0) 0xA000 else 0;
        const offset = page + @as(usize, @intCast(sy)) * video.width;
        const source = self.vram[offset..][0..video.width];
        var sx = bg.start_x;
        for (pixels) |*pixel| {
            const index = source[@intCast(sx >> 8)];
            pixel.* = .{ .index = index, .rank = if (index == 0) backdrop_rank else bg.rank };
            sx += bg.dx;
        }
        return true;
    }

    fn composeEffects(
        self: Display,
        row: *[video.width]video.Rgb,
        backgrounds: []const ?Background,
        text_pixels: *const [4][video.width]u8,
        affine: [2]?AffineLine,
        objects: *const [video.width]PalettePixel,
        backdrop: Pixel,
        effect: Effects,
    ) void {
        if (backgrounds.len == 4) {
            for (backgrounds) |layer| {
                if (layer) |bg| {
                    if (bg.mosaic_width != 1) break;
                }
            } else {
                self.composeTextEffects(row, backgrounds, text_pixels, objects, backdrop, effect);
                return;
            }
        }
        for (row, objects, 0..) |*output, object, x| {
            var mask = self.windowMask(x, object.window);
            if (self.bg_pixel_mask) |pixels| mask &= 0xF0 | pixels[x];
            var layers: Layers = .{ .front = backdrop, .behind = backdrop };
            for (backgrounds, 0..) |maybe_background, index| {
                if (mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
                const bg = maybe_background orelse continue;
                const palette_index = text_pixels[index][x - x % bg.mosaic_width];
                if (palette_index == 0) continue;
                const color = readHalf(self.palette, @as(usize, palette_index) * 2);
                layers.insert(.{ .color = color, .rank = bg.rank, .layer = @intCast(index) });
            }
            for (affine, 0..) |maybe_bg, i| {
                const bg = maybe_bg orelse continue;
                const index: u3 = @intCast(2 + i);
                if (mask & (@as(u8, 1) << index) == 0) continue;
                if (bg.pixel(self, x)) |color| layers.insert(.{ .color = color, .layer = index, .rank = bg.rank });
            }
            output.* = self.finishEffects(layers, object, mask, effect);
        }
    }

    // Sort palette indices by BG rank eight pixels at a time. Only the two
    // visible layers need palette reads when resolving OBJ and color effects.
    fn composeTextEffects(
        self: Display,
        row: *[video.width]video.Rgb,
        backgrounds: []const ?Background,
        text_pixels: *const [4][video.width]u8,
        objects: *const [video.width]PalettePixel,
        backdrop: Pixel,
        effect: Effects,
    ) void {
        const Bytes = @Vector(8, u8);
        const Words = @Vector(8, u16);
        var masks: [video.width]u8 = undefined;
        for (&masks, objects, 0..) |*mask, obj, x| {
            mask.* = self.windowMask(x, obj.window);
            if (self.bg_pixel_mask) |pixels| mask.* &= 0xF0 | pixels[x];
        }

        const empty = (@as(u16, backdrop_rank) << 11) | (backdrop_layer << 8);
        var front: [video.width / 8]Words = @splat(@splat(empty));
        var behind = front;
        for (backgrounds, 0..) |layer, i| {
            const bg = layer orelse continue;
            const rank: Words = @splat((@as(u16, bg.rank) << 11) | (@as(u16, @intCast(i)) << 8));
            const enable: Bytes = @splat(@as(u8, 1) << @intCast(i));
            for (&front, &behind, 0..) |*top, *second, group| {
                const x = group * 8;
                const mask: Bytes = masks[x..][0..8].*;
                const indices: Bytes = text_pixels[i][x..][0..8].*;
                const visible = (mask & enable) != @as(Bytes, @splat(0));
                const index = @select(u8, visible, indices, @as(Bytes, @splat(0)));
                const candidate = @select(u16, index != @as(Bytes, @splat(0)), rank | @as(Words, index), @as(Words, @splat(empty)));
                second.* = @min(second.*, @max(top.*, candidate));
                top.* = @min(top.*, candidate);
            }
        }
        for (row, objects, masks, 0..) |*output, obj, mask, x| {
            var layers: Layers = .{ .front = backdrop, .behind = backdrop };
            inline for (.{ &front, &behind }, .{ &layers.front, &layers.behind }) |packed_row, pixel| {
                const entries: [8]u16 = packed_row[x / 8];
                const entry = entries[x % 8];
                pixel.* = .{
                    .color = readHalf(self.palette, (entry & 255) * 2),
                    .rank = @truncate(entry >> 11),
                    .layer = @truncate(entry >> 8),
                };
            }
            output.* = self.finishEffects(layers, obj, mask, effect);
        }
    }

    inline fn finishEffects(self: Display, backgrounds: Layers, object: PalettePixel, mask: u8, effect: Effects) video.Rgb {
        var layers = backgrounds;
        if (mask & (1 << object_layer) != 0 and object.index != 0) layers.insert(.{
            .color = object.color(self.palette),
            .rank = object.rank,
            .layer = object_layer,
            .semitransparent = object.semitransparent,
        });
        return video.decodeColor(if (mask & (1 << 5) != 0) effect.apply(layers) else layers.front.color);
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

    fn fetchBackgroundHalf(self: Display, address: usize, latch: *u16) u16 {
        if (address < background_vram_size) latch.* = readHalf(self.vram, address);
        return latch.*;
    }

    fn fetchTextLine(self: Display, backgrounds: []const ?Background, pixels: *[4][video.width]u8, latch: *u16) void {
        // Mapped fetches are independent. An unmapped read needs the bus value
        // from the immediately preceding slot, which may belong to another BG.
        var last: LastFetch = .{ .cycle = 0, .word = latch.* };
        for (backgrounds, 0..) |maybe_bg, layer| {
            const bg = maybe_bg orelse continue;
            const mapped = if (bg.eight_bit)
                self.fetchTileRows(8, bg, layer, &pixels[layer], &last)
            else
                self.fetchTileRows(4, bg, layer, &pixels[layer], &last);
            if (!mapped) break;
        } else {
            latch.* = last.word;
            return;
        }

        self.fetchTextBusSlots(backgrounds, pixels, latch);
    }

    fn fetchTextBusSlots(self: Display, backgrounds: []const ?Background, pixels: *[4][video.width]u8, latch: *u16) void {
        // Each dot grants the text layers one bus slot apiece, in BG number order.
        // Fetch ahead of the visible pixels, even for layers hidden by the compositor.
        var entries: [4]u16 = @splat(0);
        var words: [4]u16 = @splat(0);
        var fetching: [4]bool = @splat(false);
        for (0..260) |dot| {
            for (backgrounds, 0..) |maybe_bg, layer| {
                const bg = maybe_bg orelse continue;
                const step = dot + (bg.scroll_x & 7);
                const phase = (step -% 1) & 7;
                const entry = entries[layer];
                const y = bg.sample_y & bg.yMask();
                if (fetching[layer]) {
                    const group: usize = if (bg.eight_bit) 2 else 4;
                    const tx = if (entry & 0x400 != 0) 7 - phase else phase;
                    if (phase % group == 0) {
                        const ty = if (entry & 0x800 != 0) 7 - (y & 7) else y & 7;
                        const tile_row = @as(usize, entry & 1023) * 8 + ty;
                        const address = bg.character_base + (tile_row * 8 + tx) / group * 2;
                        words[layer] = self.fetchBackgroundHalf(address, latch);
                    }
                    if (dot >= 9 and dot < 9 + video.width) {
                        const bits: usize = 16 / group;
                        const raw = words[layer] >> @intCast(tx % group * bits);
                        const index: u8 = if (bg.eight_bit) @truncate(raw) else @intCast(raw & 15);
                        const bank: u8 = if (bg.eight_bit or index == 0) 0 else @intCast((entry >> 12) * 16);
                        pixels[layer][dot - 9] = bank + index;
                    }
                    if (phase == 7) fetching[layer] = false;
                }
                const cycle = dot * 4 + layer;
                if (step >= 8 and step & 7 == 0 and cycle < text_entry_cutoff) {
                    const x = ((bg.scroll_x & ~@as(usize, 7)) + step - 8) & bg.xMask();
                    const block = (x >> 8) + (y >> 8) * @as(usize, if (bg.wide) 2 else 1);
                    const tile = ((y >> 3) & 31) * 32 + ((x >> 3) & 31);
                    entries[layer] = self.fetchBackgroundHalf(bg.screen_base + block * 0x800 + tile * 2, latch);
                    fetching[layer] = cycle < text_data_cutoff;
                }
            }
        }
    }

    const LastFetch = struct {
        cycle: usize,
        word: u16,
    };

    fn fetchTileRows(self: Display, comptime bits: usize, bg: Background, layer: usize, pixels: *[video.width]u8, last: *LastFetch) bool {
        const fine = bg.scroll_x & 7;
        const y = bg.sample_y & bg.yMask();
        const block_row = (y >> 8) * @as(usize, if (bg.wide) 2 else 1);
        const map_row = bg.screen_base + block_row * 0x800 + ((y >> 3) & 31) * 64;
        const first_cycle = (8 - fine) * 4 + layer;
        const tile_cycles = 8 * 4;
        const entry_count = (text_entry_cutoff - 1 - first_cycle) / tile_cycles + 1;
        const data_count = (text_data_cutoff - 1 - first_cycle) / tile_cycles + 1;
        var decoded: [32][8]u8 = undefined;
        var tile: usize = 0;
        while (tile < entry_count) {
            // Map entries are contiguous up to the next 32-tile screen block.
            const tile_x = (bg.scroll_x >> 3) + tile;
            const block = if (bg.wide) (tile_x >> 5) & 1 else 0;
            const column = tile_x & 31;
            const map = map_row + block * 0x800 + column * 2;
            if (map >= background_vram_size) return false;
            const end = @min(tile + 32 - column, entry_count);
            const data_end = @min(end, data_count);
            for (tile..data_end, 0..) |i, j| {
                const entry = readHalf(self.vram, map + j * 2);
                const bytes = self.textRowBytes(bits, bg.character_base, y, entry) orelse return false;
                decoded[i] = decodeTextRow(bits, bytes, entry);
            }
            if (end == entry_count) {
                // Only the final fetch on this layer can survive in the bus latch.
                const entry = readHalf(self.vram, map + (end - tile - 1) * 2);
                var cycle = first_cycle + (end - 1) * tile_cycles;
                var word = entry;
                if (entry_count == data_count) {
                    const bytes = self.textRowBytes(bits, bg.character_base, y, entry).?;
                    cycle += (1 + 8 - 16 / bits) * 4;
                    word = readHalf(bytes, if (entry & 0x400 != 0) 0 else bits - 2);
                }
                if (cycle > last.cycle) last.* = .{ .cycle = cycle, .word = word };
            }
            tile = end;
        }
        pixels.* = std.mem.asBytes(&decoded)[fine..][0..video.width].*;
        return true;
    }

    inline fn textRowBytes(self: Display, comptime bits: usize, base: usize, y: usize, entry: u16) ?*const [bits]u8 {
        const ty = (y & 7) ^ @as(usize, if (entry & 0x800 != 0) 7 else 0);
        const offset = base + (@as(usize, entry & 1023) * 8 + ty) * bits;
        if (offset >= background_vram_size) return null;
        return self.vram[offset..][0..bits];
    }

    inline fn decodeTextRow(comptime bits: usize, bytes: *const [bits]u8, entry: u16) [8]u8 {
        var indices: @Vector(8, u8) = undefined;
        if (bits == 8) {
            indices = bytes.*;
        } else {
            const packed_bytes: @Vector(4, u8) = bytes.*;
            const repeated = @shuffle(u8, packed_bytes, undefined, [8]i32{ 0, 0, 1, 1, 2, 2, 3, 3 });
            const raw = (repeated >> @as(@Vector(8, u3), .{ 0, 4, 0, 4, 0, 4, 0, 4 })) & @as(@Vector(8, u8), @splat(15));
            const bank: @Vector(8, u8) = @splat(@truncate(entry >> 8 & 0xF0));
            indices = @select(u8, raw == @as(@Vector(8, u8), @splat(0)), raw, raw | bank);
        }
        if (entry & 0x400 != 0) indices = @shuffle(u8, indices, undefined, [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 });
        return indices;
    }

    fn canComposeFrontOnly(self: Display, effect: Effects) bool {
        if (self.bg_pixel_mask != null) return false;
        const mask = self.uniformWindowMask() orelse return false;
        const layers: u8 = @truncate((self.control >> 8) & 0x1F);
        if (mask & layers != layers) return false;
        // A semitransparent OBJ can blend even when BLDCNT selects no regular effect.
        return mask & 0x20 == 0 or effect.control & 0x3FC0 == 0;
    }

    // The first covering window decides visibility for the entire row.
    // A partial window needs per-pixel priority resolution.
    fn uniformWindowMask(self: Display) ?u8 {
        if (self.control & 0xE000 == 0) return 0x3F;
        for (0..2) |i| {
            if (!self.vertical_windows.active[i]) continue;
            if (self.control & (@as(u16, 0x2000) << @intCast(i)) == 0) continue;
            const limits = self.registers.stored(0x0400_0040 + @as(u32, @intCast(i * 2)));
            const start = @min(limits >> 8, video.width);
            const end = @min(limits & 255, video.width);
            // Clip both limits, preserving whether the original interval wraps.
            const wraps = (limits >> 8) > (limits & 255);
            const inside = if (wraps) video.width - start + end else end - start;
            if (inside == 0) continue;
            if (inside < video.width) return null;
            return @truncate(self.registers.stored(0x0400_0048) >> @intCast(i * 8));
        }
        if (self.control & 0x8000 != 0) return null;
        return @truncate(self.registers.stored(0x0400_004A));
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

    fn drawObjects(self: Display, y: usize, mosaic: u16, row: *[video.width]PalettePixel) void {
        var cycles: usize = if (self.control & (1 << 5) != 0) 954 else 1210;
        for (0..16) |group| {
            var mask = objectCandidates(self.oam, group * 8, @intCast(y));
            while (mask != 0) : (mask &= mask - 1) {
                if (cycles == 0) return;
                const oam_index = group * 8 + @as(usize, @ctz(mask));
                const attributes = Object.onLine(self.oam, oam_index, y) orelse continue;
                // Invisible columns still consume the hardware scanline budget.
                const overhead: usize = if (attributes.matrix != null) 10 else 0;
                const pixel_cycles: usize = if (attributes.matrix != null) 2 else 1;
                cycles -|= overhead;
                const pixels = @min(attributes.canvas_width, cycles / pixel_cycles);
                cycles -|= attributes.canvas_width * pixel_cycles;
                self.drawObjectRow(attributes, mosaic, pixels, row);
            }
        }
    }

    fn drawObjectRow(self: Display, attributes: Object, mosaic: u16, pixels: usize, row: *[video.width]PalettePixel) void {
        const relative_y = attributes.line_y;
        const use_mosaic = attributes.first & (1 << 12) != 0;
        const sample_y = if (use_mosaic) relative_y - relative_y % mosaicSize(mosaic, 12) else relative_y;
        const line = ObjectLine.init(attributes, sample_y);
        const mosaic_width = if (use_mosaic) mosaicSize(mosaic, 8) else 1;
        if (mosaic_width == 1) {
            // A sprite is at most 128 pixels wide, so only one visible span can wrap in.
            var span: ObjectSpan = if (attributes.x < video.width)
                .{ .first = 0, .end = @min(pixels, video.width - attributes.x) }
            else
                .{ .first = 512 - attributes.x, .end = pixels };
            if (span.first >= span.end) return;
            if (attributes.matrix != null) {
                if (!span.clipAxis(line.start_x, line.dx, attributes.width)) return;
                if (!span.clipAxis(line.start_y, line.dy, attributes.height)) return;
            }
            const dest = (attributes.x + span.first) & 511;
            for (span.first..span.end, row[dest..][0 .. span.end - span.first]) |column, *pixel| {
                const x: i32 = @intCast(column);
                const tx: usize = @intCast((line.start_x + line.dx * x) >> 8);
                const ty: usize = @intCast((line.start_y + line.dy * x) >> 8);
                const index = self.objectTexel(attributes, tx, ty) orelse continue;
                pixel.plot(attributes, index);
            }
        } else {
            var start: usize = 0;
            while (start < pixels) : (start += mosaic_width) {
                const index = self.objectLinePixel(attributes, line, start) orelse continue;
                for (start..@min(pixels, start + mosaic_width)) |relative_x| {
                    const x = (attributes.x + relative_x) & 511;
                    if (x < video.width) row[x].plot(attributes, index);
                }
            }
        }
    }

    fn objectLinePixel(self: Display, object: Object, line: ObjectLine, x: usize) ?usize {
        const column: i32 = @intCast(x);
        const sx = (line.start_x + line.dx * column) >> 8;
        const sy = (line.start_y + line.dy * column) >> 8;
        if (sx < 0 or sy < 0 or sx >= object.width or sy >= object.height) return null;
        return self.objectTexel(object, @intCast(sx), @intCast(sy));
    }

    fn objectTexel(self: Display, object: Object, tx: usize, ty: usize) ?usize {
        const tile_units: usize = if (object.eight_bit) 2 else 1;
        const one_dimensional = self.control & (1 << 6) != 0;
        const stride = if (one_dimensional) object.width / 8 * tile_units else 32;
        var tile: usize = object.third & 0x03FF;
        if (object.eight_bit and !one_dimensional) tile &= ~@as(usize, 1);
        tile += ty / 8 * stride + tx / 8 * tile_units;
        // A 256-color tile spans two 32-byte character units, including at wraparound.
        const tile_y = ty & 7;
        if (object.eight_bit) tile += tile_y / 4;
        tile &= 0x3FF;
        if (self.control & 7 >= 3 and tile < 512) return null;
        const tile_base = background_vram_size + tile * 32;
        const index = tilePixel(self.vram, tile_base, tx & 7, if (object.eight_bit) tile_y & 3 else tile_y, object.eight_bit);
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

// A regular sprite can cover at most 64 lines, a double-size affine sprite 128.
// Test eight Y coordinates together. Bit zero is the earliest sprite in OAM.
fn objectCandidates(oam: *const [1024]u8, first: usize, y: u8) u8 {
    const Lanes = @Vector(8, u16);
    var attr: Lanes = undefined;
    inline for (0..8) |i| attr[i] = readHalf(oam, (first + i) * 8);
    const style = (attr >> @splat(8)) & @as(Lanes, @splat(3));
    const distance = (@as(Lanes, @splat(y)) -% attr) & @as(Lanes, @splat(255));
    const bound = @select(u16, style == @as(Lanes, @splat(3)), @as(Lanes, @splat(128)), @as(Lanes, @splat(64)));
    const height = @select(u16, style == @as(Lanes, @splat(2)), @as(Lanes, @splat(0)), bound);
    const bits: Lanes = .{ 1, 2, 4, 8, 16, 32, 64, 128 };
    return @intCast(@reduce(.Or, @select(u16, distance < height, bits, @as(Lanes, @splat(0)))));
}

const Object = struct {
    first: u16,
    second: u16,
    third: u16,
    x: usize,
    width: usize,
    height: usize,
    canvas_width: usize,
    canvas_height: usize,
    line_y: usize,
    rank: u5,
    matrix: ?[4]i16,
    eight_bit: bool,
    mode: u2,

    fn onLine(oam: []const u8, index: usize, y: usize) ?Object {
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
        const relative_y = (y -% @as(usize, @as(u8, @truncate(first)))) & 255;
        if (relative_y >= height * scale) return null;
        const matrix_offset = @as(usize, (second >> 9) & 31) * 32;
        return .{
            .first = first,
            .line_y = relative_y,
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
};

const ObjectSpan = struct {
    first: usize,
    end: usize,

    // Intersect the half-open column span with 0 <= origin + step * column < size * 256.
    fn clipAxis(span: *ObjectSpan, origin: i32, step: i32, size: usize) bool {
        const limit = @as(i32, @intCast(size)) << 8;
        // Reflect negative steps so both endpoints can use the same inequalities.
        const start = if (step < 0) limit - 1 - origin else origin;
        const delta: i32 = @intCast(@abs(step));
        const left = start + delta * @as(i32, @intCast(span.first));
        const right = start + delta * @as(i32, @intCast(span.end - 1));
        if (right < 0 or left >= limit) return false;
        if (left < 0) span.first += @intCast(1 + @divTrunc(-1 - left, delta));
        if (right >= limit) span.end -= @intCast(1 + @divTrunc(right - limit, delta));
        return span.first < span.end;
    }
};

// Starting texel and horizontal steps use 8 fractional bits, including for flipped sprites.
const ObjectLine = struct {
    start_x: i32,
    start_y: i32,
    dx: i32,
    dy: i32,

    fn init(object: Object, sample_y: usize) ObjectLine {
        const y: i32 = @intCast(sample_y);
        const w: i32 = @intCast(object.width);
        const h: i32 = @intCast(object.height);
        if (object.matrix) |matrix| {
            const left = -@as(i32, @intCast(object.canvas_width / 2));
            const line_y = y - @as(i32, @intCast(object.canvas_height / 2));
            const pa, const pb, const pc, const pd = matrix;
            return .{
                .start_x = w * 128 + pa * left + pb * line_y,
                .start_y = h * 128 + pc * left + pd * line_y,
                .dx = pa,
                .dy = pc,
            };
        }
        const flip_x = object.second & (1 << 12) != 0;
        return .{
            .start_x = if (flip_x) (w - 1) << 8 else 0,
            .start_y = (if (object.second & (1 << 13) != 0) h - 1 - y else y) << 8,
            .dx = if (flip_x) -256 else 256,
            .dy = 0,
        };
    }
};

// The two palette banks share a nine-bit index. Keep the winning index until composition.
const PalettePixel = packed struct(u16) {
    index: u9 = 0,
    rank: u5 = backdrop_rank,
    semitransparent: bool = false,
    window: bool = false,

    fn plot(self: *PalettePixel, object: Object, index: usize) void {
        if (object.mode == 2) {
            self.window = true;
        } else if (object.rank < self.rank) {
            self.* = .{
                .index = 0x100 | @as(u9, @intCast(index)),
                .rank = object.rank,
                .semitransparent = object.mode == 1,
                .window = self.window,
            };
        }
    }

    fn color(self: PalettePixel, palette: *const [1024]u8) u16 {
        return readHalf(palette, @as(usize, self.index) * 2);
    }
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
        const Channels = @Vector(4, u16);
        const shifts: @Vector(4, u4) = .{ 0, 5, 10, 0 };
        const channels = (@as(Channels, @splat(top.color)) >> shifts) & @as(Channels, @splat(31));
        const maximum: Channels = @splat(31);
        const fraction_shift: @Vector(4, u4) = @splat(4);
        const brightness: Channels = @splat(self.brightness);
        const values = if (alpha) blk: {
            const other = (@as(Channels, @splat(below.color)) >> shifts) & @as(Channels, @splat(31));
            break :blk @min(maximum, (channels * @as(Channels, @splat(self.first)) + other * @as(Channels, @splat(self.second))) >> fraction_shift);
        } else if (mode == 2)
            channels + (((maximum - channels) * brightness) >> fraction_shift)
        else
            channels - ((channels * brightness) >> fraction_shift);
        return values[0] | (values[1] << 5) | (values[2] << 10);
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

test "affine sprite clipping keeps exactly the columns inside the source axis" {
    const origins = [_]i32{ -16385, -2048, -1, 0, 1, 2047, 2048, 16384 };
    const steps = [_]i32{ -32768, -257, -256, -1, 0, 1, 255, 256, 32767 };
    for (origins) |origin| {
        for (steps) |step| {
            var span: ObjectSpan = .{ .first = 3, .end = 67 };
            const visible = span.clipAxis(origin, step, 8);
            for (3..67) |x| {
                const source = origin + step * @as(i32, @intCast(x));
                try std.testing.expectEqual(source >= 0 and source < 8 * 256, visible and x >= span.first and x < span.end);
            }
        }
    }
}

test "tile row fetches match ordered bus slots through the end of the scanline" {
    var vram: [background_vram_size + object_vram_size]u8 = undefined;
    var random = std.Random.DefaultPrng.init(19);
    random.random().bytes(&vram);
    const display: Display = .{
        .control = 0,
        .green_swap = false,
        .vertical_windows = .{},
        .registers = &.{},
        .vram = &vram,
        .palette = undefined,
        .oam = undefined,
    };
    // Four individual layers, all mapped layers, an unmapped screen block, and unmapped tile data.
    for (0..7) |scene| {
        const unmapped_map = scene == 5;
        const start_x: usize = if (scene % 2 == 0 and scene != 4) 504 else 248;
        for (0..8) |fine| {
            var layers: [4]?Background = undefined;
            for (&layers, 0..) |*layer, i| {
                layer.* = .{
                    .character_base = if (scene == 6 and i == 3) 0xC000 else 0,
                    .screen_base = if (unmapped_map and i == 0) 0xF800 else i * 0x1000,
                    .wide = i & 1 == 0,
                    .tall = true,
                    .eight_bit = i >= 2,
                    .scroll_x = start_x + ((fine + i) & 7),
                    .sample_y = if (unmapped_map) 3 + i else 259 + i,
                    .mosaic_width = 1,
                    .rank = 0,
                };
            }
            // Isolate each layer so its last map or character fetch decides the latch.
            for (&layers, 0..) |*layer, i| {
                if (scene < layers.len and i != scene) layer.* = null;
            }
            var expected: [4][video.width]u8 = undefined;
            var actual: [4][video.width]u8 = undefined;
            var expected_latch: u16 = 0xABCD;
            var actual_latch = expected_latch;
            display.fetchTextBusSlots(&layers, &expected, &expected_latch);
            display.fetchTextLine(&layers, &actual, &actual_latch);
            try std.testing.expectEqual(expected_latch, actual_latch);
            for (layers, 0..) |layer, i| {
                if (layer != null) try std.testing.expectEqualSlices(u8, &expected[i], &actual[i]);
            }
        }
    }
}

test "indexed Mode 4 rows match per-pixel composition at both page and priority boundaries" {
    var random = std.Random.DefaultPrng.init(74);
    var vram: [background_vram_size + object_vram_size]u8 = undefined;
    var palette: [1024]u8 = undefined;
    random.random().bytes(&vram);
    random.random().bytes(&palette);
    for (vram[0..0x14000], 0..) |*index, i| {
        if (i % 3 == 0) index.* = 0;
    }

    var oam: [1024]u8 = @splat(0);
    for (0..128) |i| std.mem.writeInt(u16, oam[8 * i ..][0..2], 0x0200, .little);
    // Overlap translucent and ordinary sprites on the left; the first wins OBJ ties.
    for (0..4) |i| {
        const base = 8 * i;
        std.mem.writeInt(u16, oam[base..][0..2], if (i == 0) 0x0400 else 0, .little);
        std.mem.writeInt(u16, oam[base + 2 ..][0..2], @intCast(0x4000 + i * 4), .little);
        std.mem.writeInt(u16, oam[base + 4 ..][0..2], @intCast(512 + i * 4 + (i / 2) * 1024), .little);
    }
    var regs: DisplayRegisters = .{};
    var display: Display = .{
        .control = 0x1404,
        .green_swap = false,
        .vertical_windows = .{},
        .vram = &vram,
        .palette = &palette,
        .oam = &oam,
        .registers = &regs,
    };
    const mask: [video.width]u8 = @splat(0x0F);
    var latch: u16 = 0xABCD;
    for ([_]u16{ 0x1404, 0x1414, 0x1004, 0x0404 }) |control| {
        display.control = control;
        for ([_]i16{ 0, 171, 256, -256 }) |step| {
            regs.write(0x0400_0020, @bitCast(step));
            regs.write(0x0400_0028, if (step < 0) 239 << 8 else 0);
            for (0..4) |priority| {
                regs.write(0x0400_000C, @intCast(priority));
                display.green_swap = priority & 1 != 0;
                var actual: [video.width]video.Rgb = undefined;
                var expected: @TypeOf(actual) = undefined;
                display.bg_pixel_mask = null;
                display.renderLine(7, &actual, &latch);
                // An all-visible mask selects the general compositor with the same layers.
                display.bg_pixel_mask = &mask;
                display.renderLine(7, &expected, &latch);
                try std.testing.expectEqualSlices(video.Rgb, &expected, &actual);
                try std.testing.expectEqual(@as(u16, 0xABCD), latch);
            }
        }
    }
}
