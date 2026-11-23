const std = @import("std");
const Bus = @This();
const video = @import("video.zig");
const timing = @import("timing.zig");
const DisplayRegisters = @import("display_registers.zig");
const Audio = @import("audio.zig");
const Timers = @import("timers.zig");
const DMA = @import("dma.zig");
const Serial = @import("serial.zig");
const SaveMemory = @import("save_memory.zig");
const DebugPort = @import("debug_port.zig");

pub const rom_base: u32 = 0x0800_0000;
pub const ewram_base: u32 = 0x0200_0000;
const ewram_size_bytes = 256 * 1024;
pub const iwram_base: u32 = 0x0300_0000;
pub const dispcnt_address: u32 = 0x0400_0000;
pub const dispstat_address: u32 = 0x0400_0004;
pub const vcount_address: u32 = dispstat_address + 2;
const vblank_status: u16 = 1 << 0;
const hblank_status: u16 = 1 << 1;
const vcount_match_status: u16 = 1 << 2;
const display_status_mask: u16 = 7;
const display_write_mask: u16 = 0xFF38;
pub const keyinput_address: u32 = 0x0400_0130;
pub const keycnt_address: u32 = keyinput_address + 2;
const keypad_irq: u14 = 1 << 12;
const keypad_irq_enable: u16 = 1 << 14;
const keypad_match_all: u16 = 1 << 15;
const keypad_control_mask: u16 = 0xC3FF;
pub const ie_address: u32 = 0x0400_0200;
pub const if_address: u32 = 0x0400_0202;
pub const waitcnt_address: u32 = 0x0400_0204;
const waitcnt_write_mask: u16 = 0x5FFF;
const waitcnt_prefetch_enable: u16 = 1 << 14;
pub const ime_address: u32 = 0x0400_0208;
const postflg_address: u32 = 0x0400_0300;
pub const haltcnt_address: u32 = 0x0400_0301;
const haltcnt_stop: u8 = 1 << 7;
pub const bios_size_bytes = 16 * 1024;
const irq_source_mask: u16 = 0x3FFF;
pub const palette_base: u32 = 0x0500_0000;
const palette_size_bytes = 1024;
pub const vram_base: u32 = 0x0600_0000;
const iwram_size_bytes = 32 * 1024;
const vram_size_bytes = 96 * 1024;
pub const oam_base: u32 = 0x0700_0000;
const oam_size_bytes = 1024;

// The caller owns both images and keeps them alive while the bus uses them.
rom: []const u8,
debug_port: DebugPort = .{},
save: SaveMemory = .{},
serial: Serial = .{},
dma: DMA = .{},
timers: Timers = .{},
audio: Audio = .{},
sound_dma_requests: u2 = 0,
pressed_buttons: u10 = 0,
keypad_control: u16 = 0,
display_registers: DisplayRegisters = .{},
bios: ?*const [bios_size_bytes]u8 = null,
executing_bios: bool = false,
// Cartridge fast boot starts before any emulated BIOS instruction fetch.
bios_fetch_word: u32 = 0,
post_boot: bool = false,
halted: bool = false,
ewram: [ewram_size_bytes]u8 = @splat(0),
iwram: [iwram_size_bytes]u8 = @splat(0),
palette: [palette_size_bytes]u8 = @splat(0),
vram: [vram_size_bytes]u8 = @splat(0),
oam: [oam_size_bytes]u8 = @splat(0),
// Display control storage; rendering currently uses only the mode bits.
dispcnt: u16 = 0,
bg_at_latch: ?u4 = null,
bg_pixel_mask: [video.width]u8 = @splat(0),
bg_pixels_changed: bool = false,
bg_enable_previous: u4 = 0,
bg_enable_ready: u4 = 0,
greenswap: u16 = 0,
display_phase: u64 = 0,
// Completed CPU cycles still owed to the devices during a frame run.
deferred_cycles: u64 = 0,
// Absolute machine cycle. Zero ends a batch at the current instruction.
batch_deadline: u64 = 0,

dispstat: u16 = vcount_match_status,
vcount: u8 = 0,
irq_enable: u16 = 0,
irq_flags: u16 = 0,
ime_enabled: bool = false,
waitcnt: u16 = 0,
bus_cycles: u64 = 0,
cpu_internal_cycles: u64 = 0,
immediate_dma_at: ?u64 = null,
dma_active: bool = false,
dma_sequential: bool = false,
// Start of the timed instruction, used to sample peripherals on their MMIO bus beat.
instruction_bus_origin: ?u64 = null,
timer_elapsed: u64 = 0,
// An overflow reaches IF on the following clock and the CPU two clocks later.
peripheral_irq_pending: u14 = 0,
peripheral_irq_new: u14 = 0,
peripheral_irq_sync: u14 = 0,
pending_timer_write: ?struct { address: u32, value: u32, size: u8 } = null,
rom_fetch_cycles: u64 = 0,
cartridge_prefetch: timing.CartridgePrefetch = .{},
next_rom_data_address: ?u32 = null,
iwram_data_cycles: u64 = 0,
next_fetch_nonsequential: bool = false,
prefetch_word: u32 = 0,
// The first instruction after DMA can sample the final transfer on open bus.
dma_bus_word: ?u32 = null,

/// Sample BG enables for this scanline, then advance their two-line startup delay.
pub fn scanlineDisplayControl(self: *Bus) u16 {
    const enabled: u4 = @truncate(self.dispcnt >> 8);
    const visible = if (self.bg_pixels_changed) self.bg_enable_ready else self.bg_enable_ready & enabled;
    self.bg_enable_ready = self.bg_enable_previous;
    self.bg_enable_previous = self.bg_at_latch orelse enabled;
    self.bg_at_latch = null;
    return (self.dispcnt & ~@as(u16, 0x0F00)) | (@as(u16, visible) << 8);
}

fn recordBackgroundWrite(self: *Bus, value: u16) void {
    const before: u4 = @truncate(self.dispcnt >> 8);
    const after: u4 = @truncate(value >> 8);
    if (before == after) return;
    const elapsed = if (self.instruction_bus_origin) |origin| self.bus_cycles - origin else 0;
    const phase = (self.display_phase + elapsed) % timing.cycles_per_line;
    // Once the line is rendered, HBlank writes feed the next line.
    if (phase >= timing.hblank_start and self.display_phase % timing.cycles_per_line >= timing.hblank_start) return;
    if (phase > timing.bg_enable_latch and self.bg_at_latch == null) self.bg_at_latch = before;
    // The compositor samples the live enable bits once per four clocks.
    const drawn_cycles = phase -| timing.first_pixel_merge;
    const x = @min(video.width, std.math.divCeil(u64, drawn_cycles, timing.cycles_per_pixel) catch unreachable);
    if (!self.bg_pixels_changed) @memset(&self.bg_pixel_mask, before);
    @memset(self.bg_pixel_mask[x..], after);
    self.bg_pixels_changed = true;
}

pub fn requestInterrupt(self: *Bus, sources: u14) void {
    // A device latches its request even while IRQ delivery is disabled.
    self.irq_flags |= sources;
}

/// Inject a complete button snapshot between instructions. A set bit means pressed.
/// Bit order is A, B, Select, Start, Right, Left, Up, Down, R, L.
pub fn setPressedButtons(self: *Bus, pressed: u10) void {
    const previous_match = self.keypadIrqCondition();
    self.pressed_buttons = pressed;
    if (!previous_match and self.keypadIrqCondition()) self.requestInterrupt(keypad_irq);
}

fn keypadIrqCondition(self: *const Bus) bool {
    if (self.keypad_control & keypad_irq_enable == 0) return false;
    const selected: u10 = @truncate(self.keypad_control);
    if (selected == 0) return false;
    const matching = selected & self.pressed_buttons;
    if (self.keypad_control & keypad_match_all != 0) return matching == selected;
    return matching != 0;
}

fn writeKeypadControl(self: *Bus, value: u16) void {
    const previous_match = self.keypadIrqCondition();
    self.keypad_control = value & keypad_control_mask;
    // Reevaluate on configuration writes as well as on input changes.
    if (!previous_match and self.keypadIrqCondition()) self.requestInterrupt(keypad_irq);
}

pub fn flushDeferred(self: *Bus) void {
    if (self.deferred_cycles == 0) return;
    const cycles = self.deferred_cycles;
    self.deferred_cycles = 0;
    self.advanceWithinDisplayInterval(cycles);
}

fn syncPeripheralAccess(self: *Bus, address: u32) void {
    // I/O and cartridge save accesses can observe time or change a deadline.
    const region = address >> 24;
    if (region == 0x04 or region >= 0x0D) {
        self.flushDeferred();
        self.batch_deadline = 0;
    }
    const origin = self.instruction_bus_origin orelse return;
    if (!Audio.contains(address) and !Timers.contains(address) and !Serial.contains(address) and (address < ie_address or address > ime_address + 3)) return;
    const elapsed = self.bus_cycles - origin;
    self.advanceTimers(elapsed - self.timer_elapsed);
    self.timer_elapsed = elapsed;
}

fn advanceTimers(self: *Bus, cycles: u64) void {
    if (cycles == 0) return;
    // Most instructions end before any peripheral event needs dispatch.
    if (self.pending_timer_write == null and
        self.peripheral_irq_pending | self.peripheral_irq_new | self.peripheral_irq_sync == 0 and
        self.serial.remaining == 0 and cycles < self.timers.cyclesUntilOverflow() and
        (self.audio.capture == null or cycles < @as(u64, Audio.sample_period) - self.audio.sample_phase))
    {
        self.timers.advanceBeforeOverflow(cycles);
        if (self.audio.master_enabled) self.audio.psg.advance(cycles);
        self.audio.sample_phase +%= @truncate(cycles);
        return;
    }
    self.advanceTimerEvents(cycles);
}

fn advanceTimerEvents(self: *Bus, cycles: u64) void {
    var remaining = cycles;
    if (remaining != 0) {
        if (self.pending_timer_write) |write| {
            self.advanceTimersAndSerial(1);
            switch (write.size) {
                1 => self.timers.write(u8, write.address, @truncate(write.value)),
                2 => self.timers.write(u16, write.address, @truncate(write.value)),
                4 => self.timers.write(u32, write.address, write.value),
                else => unreachable,
            }
            self.pending_timer_write = null;
            remaining -= 1;
        }
    }
    self.advanceTimersAndSerial(remaining);
}

fn advanceTimersAndSerial(self: *Bus, cycles: u64) void {
    var remaining = cycles;
    while (remaining != 0) {
        const propagating = self.peripheral_irq_pending | self.peripheral_irq_new | self.peripheral_irq_sync != 0;
        var batch: u64 = if (propagating) 1 else @min(remaining, self.timers.cyclesUntilOverflow(), self.serial.cyclesUntilCompletion());
        if (self.audio.capture != null) batch = @min(batch, @as(u64, Audio.sample_period) - self.audio.sample_phase);
        self.peripheral_irq_sync = self.peripheral_irq_new;
        self.peripheral_irq_new = self.peripheral_irq_pending & ~@as(u14, @truncate(self.irq_flags));
        self.requestInterrupt(self.peripheral_irq_pending);
        self.peripheral_irq_pending = self.timers.advance(batch) | self.serial.advance(batch);
        if (self.audio.master_enabled) self.audio.psg.advance(batch);
        if (self.timers.overflowed != 0) self.sound_dma_requests |= self.audio.clockFifos(self.timers.overflowed);
        self.audio.sample_phase +%= @truncate(batch);
        if (self.audio.sample_phase == 0) {
            if (self.audio.capture) |capture| capture.sample(&self.audio);
        }
        remaining -= batch;
    }
}

fn advancePeripherals(self: *Bus, cycles: u64) void {
    self.save.advance(cycles);
    self.advanceTimers(cycles - self.timer_elapsed);
    self.timer_elapsed = 0;
    if (self.sound_dma_requests != 0) {
        self.runDma(.special);
        self.sound_dma_requests = 0;
    }
}

// Before the next display edge, VCOUNT and DISPSTAT stay valid.
pub fn advanceWithinDisplayInterval(self: *Bus, cycles: u64) void {
    self.advancePeripherals(cycles);
    self.display_phase += cycles;
}

pub fn advanceDevices(self: *Bus, old_phase: u64, cycles: u64) void {
    self.advancePeripherals(cycles);
    const phase = (old_phase + cycles) % timing.cycles_per_frame;
    self.display_phase = phase;
    const status = self.displayStatusAt(phase);
    self.dispstat = @truncate(status);
    self.vcount = @truncate(status >> 16);
    const compare = self.dispstat >> 8;

    // Detect crossed event boundaries even if the batch ends after the flag fell.
    var events: u14 = 0;
    if (cycles >= timing.cyclesUntil(old_phase, timing.vblank_start, timing.cycles_per_frame)) {
        events |= 1;
        self.runDma(.vblank);
    }
    const old_line_phase = old_phase % timing.cycles_per_line;
    const until_hblank = timing.cyclesUntil(old_line_phase, timing.hblank_start, timing.cycles_per_line);
    if (cycles >= until_hblank) {
        events |= 2;
        const edge = (old_phase + until_hblank) % timing.cycles_per_frame;
        if (edge < timing.vblank_start) self.runDma(.hblank);
    }
    if (compare < timing.lines_per_frame) {
        const edge = @as(u64, compare) * timing.cycles_per_line;
        if (cycles >= timing.cyclesUntil(old_phase, edge, timing.cycles_per_frame)) events |= 4;
    }
    self.requestInterrupt(events & @as(u14, @truncate(self.dispstat >> 3)));
}

// DISPSTAT and VCOUNT share a word and must describe the same bus beat.
fn displayStatusAt(self: *const Bus, phase: u64) u32 {
    const line = phase / timing.cycles_per_line;
    var status = self.dispstat & ~display_status_mask;
    if (phase >= timing.vblank_start and phase < timing.vblank_end) status |= vblank_status;
    if (phase % timing.cycles_per_line >= timing.hblank_start) status |= hblank_status;
    if (line == status >> 8) status |= vcount_match_status;
    return (@as(u32, @intCast(line)) << 16) | status;
}

fn writeDisplayStatus(self: *Bus, value: u16) void {
    const previously_matching = self.dispstat & vcount_match_status != 0;
    self.dispstat = (self.dispstat & (vblank_status | hblank_status)) |
        (value & display_write_mask);
    if (self.vcount == self.dispstat >> 8) {
        self.dispstat |= vcount_match_status;
        if (!previously_matching and self.dispstat & (1 << 5) != 0) self.requestInterrupt(4);
    }
}

pub fn hasEnabledInterrupt(self: *const Bus) bool {
    return self.irq_enable & self.irq_flags != 0;
}

pub fn haltWakeLine(self: *const Bus) bool {
    // A new timer IF bit reaches HALT wake one clock before it reaches the CPU IRQ line.
    return self.irq_enable & self.irq_flags & ~@as(u16, self.peripheral_irq_new) != 0;
}

pub fn irqLine(self: *const Bus) bool {
    const synchronizing = self.peripheral_irq_new | self.peripheral_irq_sync;
    return self.ime_enabled and self.irq_enable & self.irq_flags & ~@as(u16, synchronizing) != 0;
}

pub fn arbitrateDma(self: *Bus) void {
    const ready = self.immediate_dma_at orelse return;
    if (self.dma_active or self.bus_cycles + self.cpu_internal_cycles < ready) return;
    self.immediate_dma_at = null;
    self.runDma(.immediate);
}

fn scheduleImmediateDma(self: *Bus, ready: u64) void {
    self.immediate_dma_at = @min(self.immediate_dma_at orelse ready, ready);
}

pub fn runDma(self: *Bus, trigger: DMA.Trigger) void {
    self.dma_active = true;
    defer self.dma_active = false;
    for (0..self.dma.channels.len) |index| {
        var channel = self.dma.channels[index];
        if (channel.control & DMA.enable == 0 or channel.trigger() != trigger) continue;
        if (trigger == .special) {
            if (index != 1 and index != 2) continue;
            const request: u2 = switch (channel.next_destination & ~@as(u32, 3)) {
                Audio.base + 0x40 => 1,
                Audio.base + 0x44 => 2,
                else => continue,
            };
            if (self.sound_dma_requests & request == 0) continue;
            // Sound DMA forces four words to a fixed destination.
            channel.latched_count = 4;
            channel.control = (channel.control & ~@as(u16, 0x60)) | 0x440;
        }
        if (trigger == .immediate and channel.ready_at > self.bus_cycles + self.cpu_internal_cycles) {
            self.scheduleImmediateDma(channel.ready_at);
            continue;
        }
        if (trigger == .immediate or channel.control & (1 << 9) == 0) {
            self.dma.channels[index].control &= ~DMA.enable;
        }
        if (channel.control & (1 << 10) == 0) {
            self.transferDma(u16, index, channel);
        } else {
            self.transferDma(u32, index, channel);
        }
        if (channel.control & (1 << 14) != 0) {
            self.requestInterrupt(@as(u14, 1) << @intCast(8 + index));
        }
    }
}

fn transferDma(self: *Bus, comptime T: type, index: usize, channel: DMA.Channel) void {
    const count: u32 = if (channel.latched_count != 0) channel.latched_count else if (index == 3) 0x10000 else 0x4000;
    const source_step = switch ((channel.control >> 7) & 3) {
        0 => @sizeOf(T),
        1 => -%@as(u32, @sizeOf(T)),
        2 => 0,
        else => @panic("Prohibited DMA source mode"),
    };
    const destination_step = switch ((channel.control >> 5) & 3) {
        1 => -%@as(u32, @sizeOf(T)),
        2 => 0,
        else => @sizeOf(T),
    };
    var source = alignDataAddress(T, channel.next_source);
    var destination = alignDataAddress(T, channel.next_destination);
    const eeprom_input = T == u16 and index == 3 and self.hasEepromAt(destination);
    const eeprom_output = T == u16 and index == 3 and self.hasEepromAt(source);
    if (eeprom_input) self.save.beginEepromCommand();
    // The cartridge can continue prefetching during the DMA entry and exit clocks.
    self.bus_cycles += 1;
    self.cartridge_prefetch.advance(1);
    for (0..count) |beat| {
        self.dma_sequential = beat != 0;
        const value: T = if (source < ewram_base) blk: {
            self.chargeDataAccess(T, source);
            break :blk wordLane(T, self.dma.channels[index].data_latch, destination);
        } else if (eeprom_output) blk: {
            self.chargeDataAccess(T, source);
            break :blk self.save.readEepromBit();
        } else self.readData(T, source);
        if (source >= ewram_base) {
            self.dma.channels[index].data_latch = if (T == u16) @as(u32, value) * 0x10001 else value;
        }
        self.dma_sequential = beat != 0 or romWindow(source) != null;
        if (eeprom_input) {
            self.chargeDataAccess(T, destination);
            self.save.shiftEepromCommand(value);
        } else {
            self.writeData(T, destination, value);
        }
        source = (source +% (if (romWindow(source) != null) @sizeOf(T) else source_step)) & DMA.sourceMask(index);
        destination = (destination +% destination_step) & DMA.destinationMask(index);
    }
    self.bus_cycles += 1;
    self.cartridge_prefetch.advance(1);
    if (eeprom_input) self.save.finishEepromCommand(count);
    self.dma_bus_word = self.dma.channels[index].data_latch;
    self.dma.channels[index].latched_count = self.dma.channels[index].count;
    self.dma.channels[index].next_source = source;
    self.dma.channels[index].next_destination =
        if ((channel.control >> 5) & 3 == 3) channel.destination else destination;
}

pub fn prefetchEnabled(self: *const Bus) bool {
    return self.waitcnt & waitcnt_prefetch_enable != 0;
}

pub inline fn fetch32(self: *Bus, address: u32, access: timing.Access) u32 {
    if (iwramOffset(address)) |offset| {
        if (self.immediate_dma_at == null) {
            self.next_rom_data_address = null;
            self.cartridge_prefetch = .{};
            return self.fetchIwram(u32, offset);
        }
    }
    return self.fetch(u32, address, access);
}

pub inline fn fetch16(self: *Bus, address: u32, access: timing.Access) u16 {
    // A continuing prefetch identifies the ROM window and already has its wait state.
    if (self.immediate_dma_at == null and self.cartridge_prefetch.continues(address, access)) {
        const offset = address & 0x01FF_FFFF;
        if (offset + 2 <= self.rom.len) {
            const value = std.mem.readInt(u16, self.rom[offset..][0..2], .little);
            const cycles = self.cartridge_prefetch.consume(u16, address);
            return self.finishRomFetch(u16, value, cycles);
        }
    }
    return self.fetch(u16, address, access);
}

fn fetch(self: *Bus, comptime T: type, address: u32, access: timing.Access) T {
    self.arbitrateDma();
    if (romWindow(address)) |window| {
        const value = self.readRom(T, address);
        const cycles = self.romFetchCycles(T, address, access, window);
        return self.finishRomFetch(T, value, cycles);
    }

    self.next_rom_data_address = null;
    self.cartridge_prefetch = .{};
    if (iwramOffset(address)) |offset| return self.fetchIwram(T, offset);
    if (ewramOffset(address)) |offset| {
        self.next_fetch_nonsequential = true;
        self.bus_cycles += timing.ramAccessCycles(T, 0x02);
        const value = std.mem.readInt(T, self.ewram[offset..][0..@sizeOf(T)], .little);
        self.prefetch_word = if (T == u32) value else @as(u32, value) * 0x0001_0001;
        return value;
    }
    if (address < bios_size_bytes) {
        self.next_fetch_nonsequential = false;
        self.bus_cycles += 1;
        self.bios_fetch_word = self.readBios(u32, address & ~@as(u32, 3));
        self.prefetch_word = self.bios_fetch_word;
        return wordLane(T, self.bios_fetch_word, address);
    }
    std.debug.panic("unmapped {d}-bit fetch at 0x{x:0>8}", .{ @bitSizeOf(T), address });
}

inline fn fetchIwram(self: *Bus, comptime T: type, offset: u32) T {
    self.next_fetch_nonsequential = true;
    self.bus_cycles += 1;
    const value = std.mem.readInt(T, self.iwram[offset..][0..@sizeOf(T)], .little);
    if (T == u32) {
        self.prefetch_word = value;
    } else {
        const shift: u5 = @intCast((offset & 2) * 8);
        const mask = @as(u32, 0xFFFF) << shift;
        self.prefetch_word = (self.prefetch_word & ~mask) | (@as(u32, value) << shift);
    }
    return value;
}

fn romFetchCycles(self: *Bus, comptime T: type, address: u32, access: timing.Access, window: u2) u8 {
    // The cartridge starts a fresh sequence at each 128 KiB boundary.
    const effective_access = if (self.next_fetch_nonsequential or address & 0x1_FFFF == 0)
        .nonsequential
    else
        access;
    var cycles = timing.gamePakAccessCycles(T, effective_access, self.waitcnt, window);
    if (self.prefetchEnabled()) {
        cycles = self.cartridge_prefetch.fetch(T, address, access, cycles, self.waitcnt, window);
    }
    return cycles;
}

fn finishRomFetch(self: *Bus, comptime T: type, value: T, cycles: u8) T {
    self.next_rom_data_address = null;
    self.next_fetch_nonsequential = false;
    self.rom_fetch_cycles += cycles;
    self.bus_cycles += cycles;
    self.prefetch_word = if (T == u32) value else @as(u32, value) * 0x0001_0001;
    return value;
}

// Work RAM needs DMA arbitration and access timing, but has no MMIO side effects.
fn workRamAccess(self: *Bus, comptime T: type, address: u32) ?*[@sizeOf(T)]u8 {
    const region = address >> 24;
    const bytes = switch (region) {
        0x02 => self.ewram[address % ewram_size_bytes ..][0..@sizeOf(T)],
        0x03 => self.iwram[address % iwram_size_bytes ..][0..@sizeOf(T)],
        else => return null,
    };
    self.next_fetch_nonsequential = true;
    self.chargeInternalAccess(T, @truncate(region));
    return bytes;
}

pub fn readData(self: *Bus, comptime T: type, address: u32) T {
    // The CPU uses the original address to rotate or sign-extend the aligned value.
    const aligned_address = alignDataAddress(T, address);
    self.arbitrateDma();
    if (self.workRamAccess(T, aligned_address)) |bytes| return std.mem.readInt(T, bytes, .little);
    self.chargeDataAccess(T, aligned_address);
    self.syncPeripheralAccess(aligned_address);
    if (self.debug_port.read(T, aligned_address)) |value| return value;
    // The no$gba identification probe sees open bus on a GBA without that extension.
    if (aligned_address >= 0x04FF_FA00 and aligned_address < 0x04FF_FA08) {
        return wordLane(T, self.dma_bus_word orelse self.prefetch_word, aligned_address);
    }
    if (SaveMemory.containsParallel(address)) {
        const repeats = std.math.maxInt(T) / 0xFF;
        return @as(T, self.save.readParallel(address)) * repeats;
    }
    if (T == u16 and self.hasEepromAt(address)) return self.save.eepromReady();
    if (aligned_address < bios_size_bytes) {
        if (self.executing_bios) return self.readBios(T, aligned_address);
        return wordLane(T, self.bios_fetch_word, aligned_address);
    }
    if (aligned_address < ewram_base or aligned_address >= 0x1000_0000) {
        return wordLane(T, self.dma_bus_word orelse self.prefetch_word, aligned_address);
    }
    if (aligned_address == postflg_address) return @intFromBool(self.post_boot);
    if (aligned_address >= ie_address and aligned_address + @sizeOf(T) <= 0x0400_020C) {
        var result: T = 0;
        for (0..@sizeOf(T)) |index| {
            const byte_address = aligned_address + @as(u32, @intCast(index));
            const halfword: u16 = switch (byte_address & ~@as(u32, 1)) {
                ie_address => self.irq_enable,
                if_address => self.irq_flags,
                waitcnt_address => self.waitcnt,
                ime_address => @intFromBool(self.ime_enabled),
                else => 0,
            };
            const byte: u8 = @truncate(halfword >> @intCast((byte_address & 1) * 8));
            result |= @as(T, byte) << @intCast(index * 8);
        }
        return result;
    }
    switch (aligned_address) {
        0x0400_0058...0x0400_005F, 0x0400_008C...0x0400_008F, 0x0400_00A0...0x0400_00AF, DMA.end...0x0400_00FF, 0x0400_1000...0x0400_1FFF => return wordLane(T, self.dma_bus_word orelse self.prefetch_word, aligned_address),
        0x0400_0302...0x0400_0303 => return 0,
        else => {},
    }
    if (Audio.contains(aligned_address)) return self.audio.read(T, aligned_address);
    if (Timers.contains(aligned_address)) return self.timers.read(T, aligned_address);
    if (DMA.contains(aligned_address)) {
        if ((aligned_address - DMA.base) % 12 < 8) {
            return wordLane(T, self.dma_bus_word orelse self.prefetch_word, aligned_address);
        }
        return self.dma.read(T, aligned_address);
    }
    if (aligned_address >= keyinput_address and aligned_address < keyinput_address + 4) {
        const input: u16 = @as(u10, ~self.pressed_buttons);
        const registers = @as(u32, input) | (@as(u32, self.keypad_control) << 16);
        const shift: u5 = @intCast((aligned_address - keyinput_address) * 8);
        return @truncate(registers >> shift);
    }
    if (Serial.contains(aligned_address)) return self.serial.read(T, aligned_address);
    if (paletteOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.palette[offset..][0..@sizeOf(T)], .little);
    }
    if (aligned_address >> 24 == vram_base >> 24) {
        const offset = self.vramOffset(aligned_address) orelse return 0;
        return std.mem.readInt(T, self.vram[offset..][0..@sizeOf(T)], .little);
    }
    if (oamOffset(aligned_address)) |offset| {
        return std.mem.readInt(T, self.oam[offset..][0..@sizeOf(T)], .little);
    }
    if (aligned_address >= dispcnt_address and aligned_address < dispcnt_address + 8) {
        const word = if (aligned_address < dispstat_address)
            @as(u32, self.dispcnt) | (@as(u32, self.greenswap) << 16)
        else if (self.instruction_bus_origin) |origin|
            self.displayStatusAt((self.display_phase + (self.bus_cycles - origin)) % timing.cycles_per_frame)
        else
            @as(u32, self.dispstat) | (@as(u32, self.vcount) << 16);
        const shift: u5 = @intCast((aligned_address & 3) * 8);
        return @truncate(word >> shift);
    }
    if (DisplayRegisters.contains(aligned_address)) {
        const word_address = aligned_address & ~@as(u32, 3);
        const low = self.display_registers.readable(word_address);
        const high = self.display_registers.readable(word_address + 2);
        const word = if (low == null and high == null)
            self.dma_bus_word orelse self.prefetch_word
        else
            @as(u32, low orelse 0) | (@as(u32, high orelse 0) << 16);
        return wordLane(T, word, aligned_address);
    }
    return self.readRom(T, aligned_address);
}

pub fn writeData(self: *Bus, comptime T: type, address: u32, value: T) void {
    const aligned_address = alignDataAddress(T, address);
    self.arbitrateDma();
    if (self.workRamAccess(T, aligned_address)) |bytes| return std.mem.writeInt(T, bytes, value, .little);
    self.chargeDataAccess(T, aligned_address);
    self.syncPeripheralAccess(aligned_address);
    if (self.debug_port.write(T, aligned_address, value)) return;
    if (SaveMemory.containsParallel(address)) {
        const shift: std.math.Log2Int(T) = @intCast((address - aligned_address) * 8);
        self.save.writeParallel(address, @truncate(value >> shift));
        return;
    }
    if (self.hasEepromAt(address)) return; // Commands arrive as a DMA3 bitstream.
    // BIOS, the unbacked area below EWRAM, and Game Pak ROM accept no stores.
    if (aligned_address < ewram_base or romWindow(aligned_address) != null) return;
    self.writeAligned(T, aligned_address, value);
}

fn hasEepromAt(self: *const Bus, address: u32) bool {
    return self.save.containsEeprom(self.rom.len, address);
}

fn writeAligned(self: *Bus, comptime T: type, aligned_address: u32, value: T) void {
    if (aligned_address >= 0x0400_1000 and aligned_address < 0x0400_2000 or aligned_address >= 0x0400_0302 and aligned_address < 0x0400_0304) return;
    if (T == u8 and aligned_address == postflg_address) {
        if (self.executing_bios) self.post_boot = value & 1 != 0;
        return;
    }
    if (T == u8 and aligned_address == haltcnt_address) {
        if (!self.executing_bios) return;
        if (value & haltcnt_stop != 0) @panic("GBA STOP mode is unsupported");
        self.halted = true;
        return;
    }
    if (aligned_address >= ie_address and aligned_address + @sizeOf(T) <= 0x0400_020C) {
        for (0..@sizeOf(T)) |index| {
            const byte_address = aligned_address + @as(u32, @intCast(index));
            const shift: u4 = @intCast((byte_address & 1) * 8);
            const byte: u8 = @truncate(value >> @intCast(index * 8));
            const bits = @as(u16, byte) << shift;
            const preserve = ~(@as(u16, 0xFF) << shift);
            switch (byte_address & ~@as(u32, 1)) {
                ie_address => self.irq_enable = ((self.irq_enable & preserve) | bits) & irq_source_mask,
                // IF acknowledges only the written byte, without a read-modify-write.
                if_address => self.irq_flags &= ~bits,
                waitcnt_address => {
                    self.cartridge_prefetch = .{};
                    self.waitcnt = ((self.waitcnt & preserve) | bits) & waitcnt_write_mask;
                    self.next_fetch_nonsequential = true;
                },
                ime_address => if (shift == 0) {
                    self.ime_enabled = byte & 1 != 0;
                },
                else => {}, // Unused halfwords at 0x206 and 0x20A.
            }
        }
        return;
    }
    if (T == u8 and aligned_address >= dispcnt_address and
        aligned_address < 0x0400_0058)
    {
        const halfword_address = aligned_address & ~@as(u32, 1);
        const previous: u16 = switch (halfword_address) {
            dispcnt_address => self.dispcnt,
            dispcnt_address + 2 => self.greenswap,
            dispstat_address => self.dispstat,
            vcount_address => 0,
            else => self.display_registers.stored(halfword_address),
        };
        const shift: u4 = @intCast((aligned_address & 1) * 8);
        const merged = (previous & ~(@as(u16, 0xFF) << shift)) | (@as(u16, value) << shift);
        self.writeAligned(u16, halfword_address, merged);
        return;
    }
    if (T == u32 and aligned_address >= dispcnt_address and
        aligned_address < 0x0400_0058)
    {
        self.writeAligned(u16, aligned_address, @truncate(value));
        self.writeAligned(u16, aligned_address + 2, @truncate(value >> 16));
        return;
    }
    if (paletteOffset(aligned_address)) |offset| {
        if (T == u8) {
            // Palette RAM drives both byte lanes on a byte store.
            const halfword_offset = offset & ~@as(u32, 1);
            self.palette[halfword_offset..][0..2].* = @splat(value);
        } else {
            std.mem.writeInt(T, self.palette[offset..][0..@sizeOf(T)], value, .little);
        }
        return;
    }
    if (T == u16) {
        if (aligned_address == vcount_address) return; // VCOUNT is read-only.
        if (DisplayRegisters.contains(aligned_address)) {
            self.display_registers.write(aligned_address, value);
            return;
        }
    }
    if (Audio.contains(aligned_address)) {
        self.audio.write(T, aligned_address, value);
        return;
    }
    if (Timers.contains(aligned_address)) {
        if (self.instruction_bus_origin != null) {
            self.pending_timer_write = .{ .address = aligned_address, .value = value, .size = @sizeOf(T) };
        } else self.timers.write(T, aligned_address, value);
        return;
    }
    if (DMA.contains(aligned_address)) {
        const index = (aligned_address - DMA.base) / 12;
        const enabled = self.dma.channels[index].control & DMA.enable != 0;
        self.dma.write(T, aligned_address, value);
        const channel = self.dma.channels[index];
        if (!enabled and channel.control & DMA.enable != 0 and channel.trigger() == .immediate) {
            // DMA may take ownership at a bus boundary two clocks after enable.
            const ready = self.bus_cycles + self.cpu_internal_cycles + 2;
            self.dma.channels[index].ready_at = ready;
            self.scheduleImmediateDma(ready);
        }
        return;
    }
    // The BIOS clears the unused word between serial registers and KEYINPUT.
    if (aligned_address >= 0x0400_012C and aligned_address < keyinput_address) return;
    // The BIOS also clears the unused I/O after JOYSTAT.
    if (aligned_address >= 0x0400_015C and aligned_address < ie_address) return;
    // The reset loop also clears the unused gap between RCNT and JOYCNT.
    if (aligned_address >= 0x0400_0138 and aligned_address < 0x0400_0140) return;
    if (aligned_address >= keyinput_address and aligned_address < keyinput_address + 4) {
        // KEYINPUT is read-only, including the lower half of a word write.
        if (T == u32) {
            self.writeKeypadControl(@truncate(value >> 16));
        } else if (aligned_address >= keycnt_address) {
            if (T == u16) {
                self.writeKeypadControl(value);
            } else {
                const shift: u4 = @intCast((aligned_address - keycnt_address) * 8);
                const keep = self.keypad_control & ~(@as(u16, 0xFF) << shift);
                self.writeKeypadControl(keep | (@as(u16, value) << shift));
            }
        }
        return;
    }
    if (Serial.contains(aligned_address)) {
        self.serial.write(T, aligned_address, value);
        return;
    }
    if (T == u16) {
        if (aligned_address == dispcnt_address) {
            self.recordBackgroundWrite(value);
            self.dispcnt = value;
            return;
        }
        if (aligned_address == dispcnt_address + 2) {
            self.greenswap = value & 1;
            return;
        }
        if (aligned_address == dispstat_address) {
            self.writeDisplayStatus(value);
            return;
        }
    }
    if (aligned_address >> 24 == vram_base >> 24) {
        const offset = self.vramOffset(aligned_address) orelse return;
        if (T == u8) {
            // Byte writes duplicate in background VRAM and are ignored in sprite VRAM.
            const sprite_start: u32 = if (self.bitmapMode()) 0x14000 else 0x10000;
            if (offset >= sprite_start) return;
            self.vram[offset & ~@as(u32, 1) ..][0..2].* = @splat(value);
        } else {
            std.mem.writeInt(T, self.vram[offset..][0..@sizeOf(T)], value, .little);
        }
        return;
    }
    if (oamOffset(aligned_address)) |offset| {
        // The OAM bus ignores byte stores, including stores through mirrored addresses.
        if (T != u8) std.mem.writeInt(T, self.oam[offset..][0..@sizeOf(T)], value, .little);
        return;
    }
    // The gap between DMA and timers is unused.
    if (aligned_address >= DMA.end and
        aligned_address + @sizeOf(T) <= 0x0400_0100) return;
    // The gap between display and sound registers has no write side effects.
    if (aligned_address >= 0x0400_0058 and
        aligned_address + @sizeOf(T) <= 0x0400_0060) return;
    // The gap between timers and serial registers has no write side effects.
    // Keep real peripheral registers outside this range visible as unsupported.
    if (aligned_address >= 0x0400_0110 and
        aligned_address + @sizeOf(T) <= 0x0400_0120) return;
    std.debug.panic("unmapped {d}-bit data write at 0x{x:0>8}", .{ @bitSizeOf(T), aligned_address });
}

fn chargeDataAccess(self: *Bus, comptime T: type, address: u32) void {
    self.next_fetch_nonsequential = true;
    if (SaveMemory.containsParallel(address)) {
        self.bus_cycles += self.cartridge_prefetch.stop();
        self.next_rom_data_address = null;
        self.bus_cycles += timing.saveAccessCycles(self.waitcnt);
        return;
    }
    if (romWindow(address)) |window| {
        self.bus_cycles += self.cartridge_prefetch.stop();
        const sequential = (if (self.dma_active) self.dma_sequential else self.next_rom_data_address == address) and address & 0x1_FFFF != 0;
        const access: timing.Access = if (sequential) .sequential else .nonsequential;
        self.bus_cycles += timing.gamePakAccessCycles(T, access, self.waitcnt, window);
        self.next_rom_data_address = (address & ~@as(u32, 1)) + @max(2, @sizeOf(T));
    } else {
        self.chargeInternalAccess(T, @truncate(address >> 24));
    }
}

fn chargeInternalAccess(self: *Bus, comptime T: type, region: u8) void {
    self.next_rom_data_address = null;
    const cycles = timing.ramAccessCycles(T, region);
    self.bus_cycles += cycles;
    self.cartridge_prefetch.advance(cycles);
    if (region == iwram_base >> 24) self.iwram_data_cycles += cycles;
}

fn alignDataAddress(comptime T: type, address: u32) u32 {
    comptime std.debug.assert(T == u8 or T == u16 or T == u32);
    return address & ~@as(u32, @sizeOf(T) - 1);
}

fn ewramOffset(address: u32) ?u32 {
    if (address >> 24 != ewram_base >> 24) return null;
    return address % ewram_size_bytes;
}

fn iwramOffset(address: u32) ?u32 {
    if (address >> 24 != iwram_base >> 24) return null;
    return address % iwram_size_bytes;
}

fn paletteOffset(address: u32) ?u32 {
    if (address >> 24 != palette_base >> 24) return null;
    return address % palette_size_bytes;
}

fn oamOffset(address: u32) ?u32 {
    if (address >> 24 != oam_base >> 24) return null;
    return address % oam_size_bytes;
}

fn bitmapMode(self: *const Bus) bool {
    return self.dispcnt & 7 >= 3;
}

fn vramOffset(self: *const Bus, address: u32) ?u32 {
    std.debug.assert(address >> 24 == vram_base >> 24);
    const offset = address & 0x1FFFF;
    if (offset < vram_size_bytes) return offset;
    // The final 32 KiB aliases the preceding bank, except in bitmap modes
    // where the first 16 KiB of that alias reads zero and discards writes.
    if (self.bitmapMode() and offset < 0x1C000) return null;
    return offset - 0x8000;
}

fn readBios(self: *const Bus, comptime T: type, address: u32) T {
    const bios = self.bios orelse @panic("BIOS access without a BIOS image");
    return std.mem.readInt(T, bios[address..][0..@sizeOf(T)], .little);
}

fn wordLane(comptime T: type, word: u32, address: u32) T {
    const shift: u5 = @intCast((address & 3) * 8);
    return @truncate(word >> shift);
}

fn readRom(self: *const Bus, comptime T: type, address: u32) T {
    if (romWindow(address) == null) {
        std.debug.panic("unmapped {d}-bit read at 0x{x:0>8}", .{ @bitSizeOf(T), address });
    }
    const offset = address & 0x01FF_FFFF;
    if (offset + @sizeOf(T) <= self.rom.len) {
        return std.mem.readInt(T, self.rom[offset..][0..@sizeOf(T)], .little);
    }

    // Unbacked Game Pak ROM returns the low 16 bits of the halfword address.
    // Preserve file bytes in a transfer that straddles the end of the image.
    var result: T = 0;
    for (0..@sizeOf(T)) |index| {
        const byte_offset = offset + @as(u32, @intCast(index));
        const byte = if (byte_offset < self.rom.len)
            self.rom[byte_offset]
        else
            unbackedRomByte(rom_base + byte_offset);
        result |= @as(T, byte) << @intCast(index * 8);
    }
    return result;
}

fn romWindow(address: u32) ?u2 {
    if (address < rom_base or address >= 0x0E00_0000) return null;
    return @intCast((address - rom_base) >> 25);
}

fn unbackedRomByte(address: u32) u8 {
    const halfword_address: u16 = @truncate(address >> 1);
    const shift: u4 = @intCast((address & 1) * 8);
    return @truncate(halfword_address >> shift);
}

test "Thumb BIOS fetches latch whole words for protected reads at every width" {
    const bios = comptime blk: {
        var bytes: [bios_size_bytes]u8 = @splat(0);
        bytes[0..4].* = .{ 0x11, 0x22, 0x33, 0x44 };
        bytes[4..8].* = .{ 0x55, 0x66, 0x77, 0x88 };
        break :blk bytes;
    };
    var bus: Bus = .{ .rom = &.{ 1, 2, 3, 4 }, .bios = &bios };
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, 0));
    try std.testing.expectEqual(@as(u16, 0x2211), bus.fetch16(0, .nonsequential));
    try std.testing.expectEqual(@as(u8, 0x22), bus.readData(u8, 5));
    try std.testing.expectEqual(@as(u16, 0x4433), bus.fetch16(2, .sequential));
    try std.testing.expectEqual(@as(u16, 0x6655), bus.fetch16(4, .sequential));
    try std.testing.expectEqual(@as(u32, 0x0403_0201), bus.fetch32(rom_base, .nonsequential));
    try std.testing.expectEqual(@as(u32, 0x8877_6655), bus.readData(u32, 0));
    try std.testing.expectEqual(@as(u16, 0x8877), bus.readData(u16, 2));
    try std.testing.expectEqual(@as(u8, 0x66), bus.readData(u8, bios_size_bytes - 3));
}

test "unbacked Game Pak data follows the halfword address on each byte lane" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 } };
    try std.testing.expectEqual(@as(u32, 0x0003_6655), bus.readData(u32, rom_base + 4));
    try std.testing.expectEqual(@as(u32, 0x0283_0282), bus.readData(u32, rom_base + 0x504));
    try std.testing.expectEqual(@as(u8, 0x82), bus.readData(u8, rom_base + 0x504));
    try std.testing.expectEqual(@as(u8, 0x02), bus.readData(u8, rom_base + 0x505));
    try std.testing.expectEqual(@as(u16, 0x0283), bus.fetch16(rom_base + 0x506, .sequential));
}

test "plain ROM stores consume bus cycles and preserve the image" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    bus.writeData(u16, rom_base, 0xABCD);
    try std.testing.expectEqual(@as(u64, 5), bus.bus_cycles);
    try std.testing.expectEqual(@as(u16, 0x2211), bus.readData(u16, rom_base));
    bus.writeData(u16, 0, 0xABCD);
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, 0));
}

test "WAITCNT masks reserved bits and exposes the prefetch enable bit" {
    var bus: Bus = .{ .rom = &.{} };
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, waitcnt_address));
    try std.testing.expect(!bus.prefetchEnabled());
    bus.writeData(u16, waitcnt_address, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x5FFF), bus.readData(u16, waitcnt_address));
    try std.testing.expect(bus.prefetchEnabled());
}

test "IRQ requests latch while masked and IF acknowledges only written ones" {
    var bus: Bus = .{ .rom = &.{} };
    bus.requestInterrupt(0b11);
    try std.testing.expectEqual(@as(u16, 3), bus.readData(u16, if_address));
    try std.testing.expect(!bus.irqLine());

    bus.writeData(u16, ime_address, 1);
    try std.testing.expect(!bus.irqLine());
    bus.writeData(u16, ie_address, 1);
    try std.testing.expect(bus.irqLine());
    bus.writeData(u16, if_address, 0);
    try std.testing.expect(bus.irqLine());
    bus.writeData(u32, ie_address, 0x0001_C001);
    try std.testing.expectEqual(@as(u32, 0x0002_0001), bus.readData(u32, ie_address));
    try std.testing.expect(!bus.irqLine());
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
    var bus: Bus = .{ .rom = &.{ 0x00, 0x20, 0x2A, 0x21 } };
    try std.testing.expectEqual(@as(u16, 0x212A), bus.fetch16(rom_base + 2, .sequential));
    try std.testing.expectEqual(@as(u64, 3), bus.rom_fetch_cycles);
    _ = bus.fetch16(rom_base, .sequential);
    try std.testing.expectEqual(@as(u64, 8), bus.rom_fetch_cycles);
}

test "sequential Thumb fetch charges buffered hits across the end of a ROM image" {
    var bus: Bus = .{ .rom = &.{ 0, 0, 0x34, 0x12, 0xAB } };
    bus.writeData(u16, waitcnt_address, waitcnt_prefetch_enable);
    _ = bus.fetch16(rom_base, .nonsequential);
    bus.cartridge_prefetch.advance(6);
    const before = bus.bus_cycles;
    try std.testing.expectEqual(@as(u16, 0x1234), bus.fetch16(rom_base + 2, .sequential));
    try std.testing.expectEqual(@as(u32, 0x1234_1234), bus.prefetch_word);
    try std.testing.expectEqual(@as(u16, 0x00AB), bus.fetch16(rom_base + 4, .sequential));
    try std.testing.expectEqual(before + 2, bus.bus_cycles);
}

test "ROM data reads align to their transfer width without rotating" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    const address = rom_base + 3;
    try std.testing.expectEqual(@as(u8, 0x44), bus.readData(u8, address));
    try std.testing.expectEqual(@as(u16, 0x4433), bus.readData(u16, address));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, address));
}

test "writes to the unused timer to serial gap leave bus state unchanged" {
    // Exercise every transfer width used by BIOS register clearing loops.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, ie_address, 3);
    for (0x0400_0110..0x0400_0120) |address| {
        bus.writeData(u8, @intCast(address), 0xFF);
        bus.writeData(u16, @intCast(address), 0xFFFF);
        bus.writeData(u32, @intCast(address), 0xFFFF_FFFF);
    }
    try std.testing.expectEqual(@as(u16, 3), bus.irq_enable);
    try std.testing.expectEqual(@as(u64, 0), bus.iwram_data_cycles);
    try std.testing.expect(bus.next_fetch_nonsequential);
}

test "bus routes serial registers across access widths" {
    // Verify dispatch and CPU alignment without involving a ROM or BIOS.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, Serial.base + 8, 0x1000);
    bus.writeData(u32, Serial.base, 0x1234_5678);
    bus.writeData(u8, Serial.base + 1, 0xAB);
    try std.testing.expectEqual(@as(u16, 0xAB78), bus.readData(u16, Serial.base));
    try std.testing.expectEqual(@as(u32, 0x1234_AB78), bus.readData(u32, Serial.base));
}

test "display control word writes include the green swap register" {
    // BIOS block stores use words across adjacent 16-bit display registers.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, dispcnt_address, 0xFFFF_0403);
    try std.testing.expectEqual(@as(u16, 0x0403), bus.readData(u16, dispcnt_address));
    try std.testing.expectEqual(@as(u32, 0x0001_0403), bus.readData(u32, dispcnt_address));
    bus.writeData(u16, dispcnt_address + 2, 2);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, dispcnt_address + 2));
}

test "BIOS display reset word stores and byte updates preserve status" {
    // Exercise the complete display reset span, including read-only and unused addresses.
    var bus: Bus = .{ .rom = &.{} };
    bus.advanceDevices(0, timing.vblank_start);
    for (0..0x60 / 4) |index| {
        bus.writeData(u32, dispcnt_address + @as(u32, @intCast(index * 4)), 0);
    }
    try std.testing.expectEqual(@as(u16, 1), bus.dispstat);
    bus.writeData(u8, dispcnt_address + 1, 4);
    bus.writeData(u8, dispcnt_address, 3);
    try std.testing.expectEqual(@as(u16, 0x0403), bus.dispcnt);
    bus.writeData(u8, 0x0400_0011, 0xFF);
    try std.testing.expectEqual(@as(u16, 0x0100), bus.display_registers.values[4]);
}

test "system control byte lanes preserve masks and acknowledge only written IF bits" {
    var bus: Bus = .{ .rom = &.{} };
    bus.requestInterrupt(0x3FFF);
    bus.writeData(u8, if_address + 1, 1);
    try std.testing.expectEqual(@as(u16, 0x3EFF), bus.readData(u16, if_address));
    bus.writeData(u8, ie_address + 1, 0xFF);
    bus.writeData(u8, ie_address, 0x55);
    try std.testing.expectEqual(@as(u16, 0x3F55), bus.readData(u16, ie_address));
    bus.writeData(u32, waitcnt_address, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x5FFF), bus.readData(u32, waitcnt_address));
    bus.writeData(u8, waitcnt_address, 0);
    try std.testing.expectEqual(@as(u16, 0x5F00), bus.readData(u16, waitcnt_address));
    bus.writeData(u32, ime_address, 1);
    bus.writeData(u8, ime_address + 1, 0xFF);
    try std.testing.expectEqual(@as(u32, 1), bus.readData(u32, ime_address));
}

test "BIOS DMA reset stores reach every channel and the unused trailing gap" {
    // Word stores must route to channels without accidentally touching timers.
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, DMA.base, 0x0300_1234);
    bus.writeData(u16, DMA.base + 10, 0x4000);
    try std.testing.expectEqual(@as(u16, 0x4000), bus.readData(u16, DMA.base + 10));
    for (0..(0x100 - 0xB0) / 4) |index| {
        bus.writeData(u32, DMA.base + @as(u32, @intCast(index * 4)), 0);
    }
    for (bus.dma.channels) |channel| {
        try std.testing.expectEqualDeep(DMA.Channel{}, channel);
    }
}

test "immediate DMA waits for two clocks and lets an in-flight CPU read finish" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, iwram_base, 0x1234);
    bus.writeData(u32, DMA.base, iwram_base);
    bus.writeData(u32, DMA.base + 4, ewram_base);
    bus.writeData(u32, DMA.base + 8, 0x8000_0001);

    // The one-clock IWRAM read leaves one startup clock outstanding. The
    // following three-clock EWRAM read owns the bus until it completes.
    _ = bus.readData(u16, iwram_base);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, ewram_base));
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readData(u16, ewram_base));
}

test "HBlank DMA repeats with a running source and a reloaded destination" {
    var bus: Bus = .{ .rom = &.{} };
    const channel = DMA.end - 12;
    bus.writeData(u32, iwram_base, 0x5678_1234);
    bus.writeData(u32, channel, iwram_base);
    bus.writeData(u32, channel + 4, palette_base);
    // DMA3 transfers one halfword on each visible HBlank, reloading the destination.
    bus.writeData(u32, channel + 8, 0xE260_0001);

    bus.advanceDevices(0, timing.hblank_start - 1);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, palette_base));
    bus.advanceDevices(timing.hblank_start - 1, 1);
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readData(u16, palette_base));
    try std.testing.expectEqual(@as(u16, 1 << 11), bus.irq_flags);
    bus.advanceDevices(timing.hblank_start, timing.cycles_per_line);
    try std.testing.expectEqual(@as(u16, 0x5678), bus.readData(u16, palette_base));
    try std.testing.expect(bus.readData(u16, channel + 10) & DMA.enable != 0);

    bus.advanceDevices(timing.vblank_start, timing.hblank_start);
    try std.testing.expectEqual(@as(u16, 0x5678), bus.readData(u16, palette_base));
}

test "DMA3 writes and reads both EEPROM capacities over the Game Pak bus" {
    const TestDma = struct {
        fn transfer(bus: *Bus, source: u32, destination: u32, count: u32) void {
            const channel = DMA.end - 12;
            bus.writeData(u32, channel, source);
            bus.writeData(u32, channel + 4, destination);
            bus.writeData(u32, channel + 8, 0x8000_0000 | count);
            _ = bus.readData(u32, ewram_base); // DMA becomes ready during this CPU access.
            bus.arbitrateDma();
        }

        fn encode(bus: *Bus, value: u128, count: u32) void {
            for (0..count) |index| {
                const bit = value >> @intCast(count - 1 - index);
                bus.writeData(u16, ewram_base + 2 * @as(u32, @intCast(index)), @truncate(bit & 1));
            }
        }
    };
    const port: u32 = 0x0DFF_FF00;
    const payload: u64 = 0x0102_0304_0506_0708;
    for ([_]u32{ 6, 14 }) |address_bits| {
        var bus: Bus = .{ .rom = &.{}, .save = .{ .kind = .eeprom } };
        const block: u128 = if (address_bits == 6) 63 else 1023;
        const command = (@as(u128, 2) << @intCast(address_bits)) | block;
        const write_count = 67 + address_bits;
        TestDma.encode(&bus, (command << 65) | (@as(u128, payload) << 1), write_count);
        TestDma.transfer(&bus, ewram_base, port, write_count);
        try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, port));
        bus.advanceDevices(0, 108_368);
        try std.testing.expectEqual(@as(u16, 1), bus.readData(u16, port));
        try std.testing.expectEqual(if (address_bits == 6) @as(usize, 512) else 8192, bus.save.bytes().len);

        const read_count = 3 + address_bits;
        TestDma.encode(&bus, ((@as(u128, 3) << @intCast(address_bits)) | block) << 1, read_count);
        TestDma.transfer(&bus, ewram_base, port, read_count);
        TestDma.transfer(&bus, port, iwram_base, 68);
        var received: u64 = 0;
        for (4..68) |index| {
            const bit = bus.readData(u16, iwram_base + 2 * @as(u32, @intCast(index)));
            received = (received << 1) | bit;
        }
        try std.testing.expectEqual(payload, received);
    }
}

test "keypad word accesses pair active-low input with masked control" {
    var bus: Bus = .{ .rom = &.{} };
    try std.testing.expectEqual(@as(u32, 0x0000_03FF), bus.readData(u32, keyinput_address));
    bus.setPressedButtons(0x201);
    bus.writeData(u32, keyinput_address, 0xFFFF_0000);
    try std.testing.expectEqual(@as(u32, 0xC3FF_01FE), bus.readData(u32, keyinput_address));
    bus.writeData(u8, keycnt_address, 0x01);
    bus.writeData(u8, keyinput_address + 1, 0xFF);
    try std.testing.expectEqual(@as(u8, 1), bus.readData(u8, keyinput_address + 1));
    try std.testing.expectEqual(@as(u16, 0xC301), bus.readData(u16, keycnt_address));
}

test "keypad any and all matches latch IF independently of CPU delivery" {
    var bus: Bus = .{ .rom = &.{} };
    bus.setPressedButtons(1);
    bus.writeData(u16, keycnt_address, 0x4003);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
    try std.testing.expect(!bus.irqLine());
    bus.writeData(u16, if_address, keypad_irq);
    bus.writeData(u16, keycnt_address, 0xC003);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.setPressedButtons(7);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
    bus.writeData(u16, if_address, keypad_irq);
    bus.setPressedButtons(7);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.setPressedButtons(0);
    bus.setPressedButtons(3);
    try std.testing.expectEqual(keypad_irq, bus.irq_flags);
}

test "palette RAM mirrors share storage and byte writes update only the addressed color" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, palette_base + 0x1FC, 0x7C00_1234);
    bus.writeData(u8, palette_base + 0x5FD, 0x5A);
    try std.testing.expectEqual(@as(u32, 0x7C00_5A5A), bus.readData(u32, palette_base + 0x1FC));
    try std.testing.expectEqual(@as(u8, 0x7C), bus.readData(u8, palette_base + 0x5FF));
    bus.writeData(u16, 0x05FF_FFFE, 0xFEDC);
    try std.testing.expectEqual(@as(u16, 0xFEDC), bus.readData(u16, palette_base + 0x3FE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, palette_base));
}

test "VRAM widths and mirrors share storage with a hole in bitmap modes" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, vram_base + 0x30000, 0x4433_2211);
    try std.testing.expectEqual(@as(u8, 0x33), bus.readData(u8, vram_base + 0x18002));
    try std.testing.expectEqual(@as(u16, 0x2211), bus.readData(u16, vram_base + 0x10000));
    bus.writeData(u16, dispcnt_address, 3);
    bus.writeData(u32, vram_base + 0x18000, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, vram_base + 0x18000));
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, vram_base + 0x10000));
    bus.writeData(u32, vram_base + 0x1FFFC, 0xAABB_CCDD);
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), bus.readData(u32, vram_base + 0x17FFC));
}

test "VRAM byte stores honor the background and sprite boundary" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u8, vram_base + 0xFFFF, 0x12);
    bus.writeData(u8, vram_base + 0x10000, 0x34);
    try std.testing.expectEqual(@as(u16, 0x1212), bus.readData(u16, vram_base + 0xFFFE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vram_base + 0x10000));
    bus.writeData(u16, dispcnt_address, 3);
    bus.writeData(u8, vram_base + 0x13FFF, 0x56);
    bus.writeData(u8, vram_base + 0x1C000, 0x78);
    try std.testing.expectEqual(@as(u16, 0x5656), bus.readData(u16, vram_base + 0x13FFE));
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vram_base + 0x14000));
}

test "OAM mirrors preserve both sprite attributes and affine coefficients" {
    var bus: Bus = .{ .rom = &.{} };
    // The last two halfwords hold a sprite attribute and an affine coefficient.
    bus.writeData(u32, oam_base + 0x7FC, 0xFEDC_1234);
    try std.testing.expectEqual(@as(u16, 0x1234), bus.readData(u16, oam_base + 0x3FC));
    try std.testing.expectEqual(@as(u8, 0xFE), bus.readData(u8, 0x07FF_FFFF));
    bus.writeData(u8, oam_base + 0x3FD, 0);
    bus.writeData(u8, 0x07FF_FFFE, 0);
    try std.testing.expectEqual(@as(u32, 0xFEDC_1234), bus.readData(u32, oam_base + 0x3FC));
    bus.writeData(u16, 0x07FF_FFFE, 0x0100);
    try std.testing.expectEqual(@as(u32, 0x0100_1234), bus.readData(u32, oam_base + 0x7FC));
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, oam_base));
}

test "EWRAM data and instruction accesses share mirrored storage" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, ewram_base + 0x40001, 0x4433_2211);
    bus.writeData(u8, ewram_base + 1, 0xAA);
    bus.writeData(u16, 0x02FC_0003, 0x6655);
    try std.testing.expectEqual(@as(u32, 0x6655_AA11), bus.readData(u32, ewram_base));
    try std.testing.expectEqual(@as(u8, 0x55), bus.readData(u8, ewram_base + 0x80002));
    try std.testing.expectEqual(@as(u16, 0x6655), bus.fetch16(ewram_base + 0xC0002, .sequential));
    try std.testing.expectEqual(@as(u32, 0x6655_AA11), bus.fetch32(ewram_base, .nonsequential));
    bus.writeData(u16, 0x02FF_FFFE, 0xCDEF);
    try std.testing.expectEqual(@as(u16, 0xCDEF), bus.readData(u16, ewram_base + 0x3FFFE));
    try std.testing.expectEqual(@as(u32, 0), bus.readData(u32, iwram_base));
}

test "the mirrored IRQ handler address shares the top word of IWRAM" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, 0x03FF_FFFC, 0x0800_0100);
    try std.testing.expectEqual(@as(u32, 0x0800_0100), bus.readData(u32, 0x0300_7FFC));
}

test "IWRAM loaded as data can execute through its mirrors" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u32, iwram_base + 4, 0xE1A0_0000);
    try std.testing.expectEqual(@as(u32, 0xE1A0_0000), bus.fetch32(0x03FF_8004, .nonsequential));
    try std.testing.expectEqual(@as(u16, 0xE1A0), bus.fetch16(iwram_base + 6, .sequential));
    try std.testing.expectEqual(@as(u64, 0), bus.rom_fetch_cycles);
}

test "timed display reads sample both HBlank edges on the data beat" {
    var bus: Bus = .{ .rom = &.{} };
    bus.advanceDevices(0, timing.hblank_start - 2);
    bus.instruction_bus_origin = bus.bus_cycles;
    try std.testing.expectEqual(@as(u16, vcount_match_status), bus.readData(u16, dispstat_address));
    try std.testing.expectEqual(@as(u16, vcount_match_status | hblank_status), bus.readData(u16, dispstat_address));

    bus.instruction_bus_origin = null;
    bus.advanceDevices(timing.hblank_start - 2, timing.cycles_per_line - timing.hblank_start + 1);
    bus.instruction_bus_origin = bus.bus_cycles;
    try std.testing.expectEqual(@as(u32, 1 << 16), bus.readData(u32, dispstat_address));
}

test "display timing updates scanline status and latches each enabled IRQ" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, dispstat_address, 0xA0FF);
    try std.testing.expectEqual(@as(u16, 0xA038), bus.readData(u16, dispstat_address));
    bus.advanceDevices(0, timing.hblank_start - 1);
    try std.testing.expectEqual(@as(u16, 0), bus.irq_flags);
    bus.advanceDevices(timing.hblank_start - 1, 1);
    try std.testing.expectEqual(@as(u16, 0xA03A), bus.readData(u16, dispstat_address));
    try std.testing.expectEqual(@as(u16, 2), bus.irq_flags);
    bus.writeData(u16, if_address, 2);
    bus.advanceDevices(timing.vblank_start - 1, 1);
    try std.testing.expectEqual(@as(u32, 0x00A0_A03D), bus.readData(u32, dispstat_address));
    try std.testing.expectEqual(@as(u16, 5), bus.irq_flags);
    bus.writeData(u32, dispstat_address, 0xFFFF_A038);
    try std.testing.expectEqual(@as(u8, 160), bus.readData(u8, vcount_address));
    bus.advanceDevices(timing.vblank_start, timing.vblank_end - timing.vblank_start);
    try std.testing.expectEqual(@as(u32, 0x00E3_A038), bus.readData(u32, dispstat_address));
    bus.advanceDevices(timing.vblank_end, timing.cycles_per_line);
    try std.testing.expectEqual(@as(u16, 0), bus.readData(u16, vcount_address));
}

test "Game Pak mirrors use their own wait states and restart at a page boundary" {
    var bus: Bus = .{ .rom = &.{ 0x11, 0x22, 0x33, 0x44 } };
    try std.testing.expectEqual(@as(u32, 0x4433_2211), bus.readData(u32, 0x0A00_0000));
    try std.testing.expectEqual(@as(u64, 10), bus.bus_cycles);
    _ = bus.readData(u32, 0x0A00_0004);
    try std.testing.expectEqual(@as(u64, 20), bus.bus_cycles);
    _ = bus.readData(u16, 0x0C01_FFFE);
    _ = bus.readData(u16, 0x0C02_0000);
    try std.testing.expectEqual(@as(u64, 30), bus.bus_cycles);
    try std.testing.expectEqual(@as(u16, 0x2211), bus.fetch16(0x0C00_0000, .sequential));
    try std.testing.expectEqual(@as(u64, 35), bus.bus_cycles);
}

test "timer IRQ propagates through IF to the CPU while repeated overflows keep the line high" {
    var bus: Bus = .{ .rom = &.{} };
    bus.writeData(u16, ie_address, 8);
    bus.writeData(u16, ime_address, 1);
    bus.writeData(u32, Timers.base, 0x00C0_FFFF);
    bus.advanceDevices(0, 2); // Load, then overflow.
    try std.testing.expect(!bus.hasEnabledInterrupt());
    bus.advanceDevices(2, 1);
    try std.testing.expect(bus.hasEnabledInterrupt());
    try std.testing.expect(!bus.irqLine());
    bus.advanceDevices(3, 1);
    try std.testing.expect(!bus.irqLine());
    bus.advanceDevices(4, 1);
    try std.testing.expect(bus.irqLine());
    bus.advanceDevices(5, 8);
    try std.testing.expect(bus.irqLine());
    bus.writeData(u16, if_address, 8);
    try std.testing.expect(!bus.irqLine());
    bus.advanceDevices(13, 3);
    try std.testing.expect(bus.irqLine());
}
