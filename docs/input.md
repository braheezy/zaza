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

The runner writes a Mode 3 or Mode 4 BMP after the requested number of frames.
Give each run a fresh output path to avoid overwriting a previous capture. The
replay uses emulated time, so its input is independent of host timing or window
focus. To drive the machine from Zig, use `Machine.runFrame(buttons)` with a
complete mask built from `input.Button` values.
