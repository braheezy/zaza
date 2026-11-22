# Playing and replaying input

On macOS, build the player and open a cartridge.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zaza /path/to/game.gba
```

Live mode plays through the default audio device at 30% volume. Put
`--volume 5` before the ROM path for a quiet sound test, or `--mute` for silence.

| GBA button | Keyboard |
| --- | --- |
| D-pad | Arrow keys |
| A, B | X, Z |
| L, R | A, S |
| Start, Select | Enter, left Shift |

The window has a fixed 720 × 480 point content area (3× the GBA display).
Escape closes the player. Losing focus releases all keys.

## Operating a game from an agent

Start `zaza session game.gba` as a subprocess and keep its stdin and stdout
open. The game starts at frame zero and waits while the agent examines the
screen or chooses an action. Send one newline-terminated command at a time.

| Request | Effect |
| --- | --- |
| `step 60 none` | Advance 60 frames with all buttons released. |
| `step 4 Right A` | Hold exactly Right and A for four frames. |
| `screen /tmp/turn-1.bmp` | Write the current 240×160 framebuffer to a fresh path without advancing. |
| `checkpoint` | Remember the machine and frame number in the session’s single in-memory slot. A later checkpoint replaces it. |
| `restore` | Return to the remembered frame. The checkpoint remains available until replaced or the session exits. |
| `quit` or end of input | Flush any configured cartridge save and exit. |

Step, screen, checkpoint, and restore reply on stdout with `ok <current frame>`.
Restoring before the first checkpoint returns `error NoCheckpoint` and leaves the game running.
Invalid commands and capture errors reply with `error <reason>`; the session
stays open. Quit closes stdout. Guest logs and fatal errors go to stderr.
To reproduce a run, keep the initial ROM, BIOS, save, and sequence of step, checkpoint, and restore commands.

## Headless execution

The same executable can run a complete experiment in one command. Use
`zaza snapshot game.gba 10000 frame.bmp` for an instruction-count snapshot,
`zaza demo frame.bmp` for the built-in cartridge, or `zaza replay` for
frame-indexed input and optional WAV capture. These commands and `session`
work without opening a window or an audio device. Build with
`zig build -Ddesktop=false` to omit Mach and retain the same CLI.

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

The runner writes a native-resolution BMP after the requested number of frames.
Modes 0 through 5 capture each visible scanline before HBlank DMA. The instruction-count
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
./zig-out/bin/zaza --save /path/to/game.sav /path/to/game.gba
```

Zaza writes changed data after a successful capture or on normal window
exit. It rejects a save whose size does not match the cartridge and uses
an adjacent `.lock` file to prevent two Zaza sessions from writing the same save.

## Silent audio testing

Replay captures both square channels, wave RAM, noise, and Direct Sound A and B
as stereo, signed 16-bit PCM at
32,768 Hz. It writes the WAV on the emulated clock without opening an audio
device. Input is optional. Use fresh output paths for each run.

```sh
zig build
zig build audio-test-rom
zig-out/bin/zaza replay zig-out/roms/direct-sound.gba 1 /tmp/direct-sound.bmp --wav /tmp/direct-sound.wav
```

The test cartridge sends an ascending ramp to the left channel on timer 0
and a descending ramp at half the rate to the right channel on timer 1.
DMA1 and DMA2 refill the respective FIFOs. `zig build test` checks every
captured sample of the first frame, including signed wraparound and refills.
The first frame runs from cartridge startup to VBlank. Later frames span
a full display period. The WAV contains the digital mix before analog output filtering.
The PSG oscillators, length counters, sweep, and envelopes also advance when
a WAV is not being recorded.
