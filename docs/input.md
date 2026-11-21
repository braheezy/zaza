# Playing and replaying input

On macOS, run a ROM in the live Mach window with:

```sh
zig build window -Ddesktop=true -- --live ../ziggba/zig-out/keydemo.gba
```

| GBA button | Keyboard |
| --- | --- |
| D-pad | Arrow keys |
| A, B | X, Z |
| L, R | A, S |
| Start, Select | Enter, left Shift |

The window has a fixed 720 × 480 point content area (3× the GBA display).
Escape closes the viewer. Losing focus releases all keys. The old window
command with a ROM and an instruction count still shows a static snapshot.

For automated runs, use the headless executable. For example:

```sh
zig build
printf '2 A\n18 none\n' > /tmp/zaza-input.txt
zig-out/bin/zaza replay ../ziggba/zig-out/keydemo.gba 20 /tmp/keydemo.bmp \
  --input-file /tmp/zaza-input.txt
```

For short scripts, use `--input $'2 A\n18 none'` in place of `--input-file`.
A row gives a zero-based frame number and the complete set of held buttons.
Start with all buttons released. Apply frame 0 before running to the first
VBlank, then apply each subsequent frame before running to the next VBlank.
Buttons stay held until a later row replaces the set. Use `none` to release
everything and spaces to hold multiple buttons, such as `12 Right A`.
Names are case-insensitive. Frame numbers must increase, and all rows must
fall within the requested frame count. Blank lines and `#` comments are allowed.

The runner writes a Mode 0, 3, or 4 BMP after the requested number of frames.
Mode 0 captures each visible scanline before HBlank DMA. The instruction-count
viewer instead renders the current register and memory values as one image.
Give each run a fresh output path to avoid overwriting a previous capture. The
replay uses emulated time, so its input is independent of host timing or window
focus. To drive the machine from Zig, use `Machine.runFrame(buttons)` with a
complete mask built from `input.Button` values.

Use `--boot` before the ROM path or the `replay` command to run the BIOS from
its reset vector. Replay frame numbers then include the BIOS startup sequence.
For example, the jsmolka BIOS test reaches its results screen within this run.

```sh
zig-out/bin/zaza --boot replay /path/to/bios.gba 400 /tmp/bios-test.bmp \
  --input '0 none'
```

To select a different BIOS, add `--bios /path/to/bios.bin` before the command.

## Cartridge saves

Zaza detects save hardware from the ROM's save-type signature. Use
`--save-type sram`, `flash64`, `flash128`, `eeprom`, `eeprom512`,
`eeprom8k`, or `none` to override detection. The `eeprom` setting infers
capacity from the game's DMA commands or the size of an existing save.

Add `--save /path/to/game.sav` to load and persist the cartridge's raw save
data. Supply the save options before the command or ROM. Without a save path,
the cartridge's save data stays in memory for the session.

```sh
zig build window -Ddesktop=true -- --save /path/to/game.sav --live /path/to/game.gba
```

Zaza writes changed data after a successful capture or on normal window
exit. It rejects a save whose size does not match the cartridge and uses
an adjacent `.lock` file to prevent two Zaza sessions from writing the same save.
