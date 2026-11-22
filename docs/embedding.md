# Embedding libzaza

Add Zaza as a Zig package dependency named `zaza` using the Zig version in its
manifest. In your build, import the public module into your host executable.

```zig
const zaza = b.dependency("zaza", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("libzaza", zaza.module("libzaza"));
```

A terminal renderer, native app or agent can all use the same frame loop.
Allocate one emulator per console. ROM and optional custom BIOS bytes are
borrowed and must remain alive and immutable, including while checkpoints exist.

```zig
const gba = @import("libzaza");

const emu = try allocator.create(gba.Emulator);
defer allocator.destroy(emu);
try emu.init(rom, .{}); // Cartridge entry point, bundled emibios.

var pixels: gba.video.Frame = undefined;
const buttons = gba.input.Button.a.mask() | gba.input.Button.right.mask();
try emu.runFrame(buttons);
try emu.snapshotFrame(&pixels);
// pixels[y][x] has red, green and blue fields. The host owns the copy.
```

Pass the complete held-button mask each frame, or zero to release all buttons.
One call advances to the next VBlank. The host controls pacing
(`gba.frame_period_ns`) and serializes calls for each instance. A terminal host
can combine two rows of the 240 × 160 frame per row of half-block characters.
To boot a supplied BIOS from reset, pass `.{ .bios = bios, .boot = .bios }`.

Audio is optional. Attach a `gba.AudioCapture{ .writer = writer }` with
`setAudioCapture(&capture)`. The writer receives interleaved left and right
signed 16-bit little-endian samples at `gba.sample_rate` during emulation.
Keep the capture and writer at stable addresses until detached with
`setAudioCapture(null)`. A streaming host can reset the capture byte counter
after consuming each batch. The desktop player handles device buffering and
resampling. The CLI uses the same output for WAV files.

Use `saveMemory().load(bytes)` to import battery data and copy
`saveMemory().bytes()` to persist it. Clear `dirty` after storage succeeds.
For branching a session, allocate an `Emulator.Checkpoint`, call
`checkpoint(out)` and later `restore(out)`. Restoring keeps the destination's
audio sink. Checkpoints are in-process values and borrow the original images.

The public distribution is a Zig module. Its build fetches the pinned emibios
image on cache miss. Ship the emibios license and notice with binaries that
embed it. Mach, OS audio devices, configuration files and window creation all
belong to the desktop host.
