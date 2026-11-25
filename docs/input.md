# Playing and replaying input

On macOS, build the player and open a cartridge.

```sh
zig build desktop -Doptimize=ReleaseFast
./zig-out/bin/zaza
```

Choose **File → Open ROM…** or press **⌘O** to pick a `.gba` file. You can
also pass a ROM path at launch. Opening another ROM starts it in the same
window. Canceling the picker or selecting a file that fails to load keeps the
current cartridge running.

Choose **Emulation → Pause** or press **⌘P** to freeze the game. Choose
**Resume** or press **⌘P** again to continue from the same frame. Opening a
new cartridge starts it running.

For headless automation, build with `zig build cli` and run `zaza-cli`.

Live mode plays through the default audio device at 30% volume. Put
`--volume 5` before the ROM path for a quiet sound test, or `--mute` for silence.

| GBA button | Keyboard |
| --- | --- |
| D-pad | Arrow keys |
| A, B | X, Z |
| L, R | A, S |
| Start, Select | Enter, left Shift |

The window has a fixed 720 × 480 point content area (3× the GBA display).
Escape closes the player by default. Losing focus releases all keys.

## Save states

Press **⌘S** before a difficult section and **⌘L** to retry from that frame.
Quick Save replaces the quick slot immediately. The window title confirms each
operation. Loading while paused shows the restored frame and keeps the game paused.

Open **States → Slot 1**, **Slot 2**, or **Slot 3** to keep longer-lived
checkpoints. Each slot shows **Empty** or **Saved** and has commands to save,
load, or delete. Replacing or deleting a numbered state asks for confirmation.

States survive quitting and reopening Zaza. Moving or renaming the ROM keeps
its slots. Zaza stores them under `~/Library/Application Support/Zaza/States/`
with a separate directory for each ROM, BIOS, and save-hardware configuration.
A state includes the cartridge’s emulated save memory. If you use `--save`,
restored changes to that memory are written on the usual cartridge-save flush.

### Disk format

Version 1 begins with the six ASCII bytes `ZAZAST`, a zero byte, and a version
byte. Next come two 32-byte BLAKE3 digests. The first identifies the BIOS
bytes, initial save-hardware kind byte, and ROM bytes concatenated in that order.
The second covers the remaining machine-state payload. Files are replaced atomically.

The payload follows the Zig machine fields in declaration order, including the
framebuffer. It omits the borrowed ROM, BIOS, and audio-capture pointers.
Arrays use element order. Integers and enum tags use little endian, rounded up
to whole bytes, and signed values use two’s complement. Booleans use one byte
(0 or 1). Optionals use a boolean followed by the value when present. A change
to field order, width, or meaning requires a format revision.

## FPS and emulator hotkeys

Press **F3** to toggle FPS in the upper-right corner. The counter measures distinct
game frames submitted for display over the last second. It updates in tenths of
a frame per second. Headless screenshots contain only the GBA image.

The desktop player reads `zaza.ini` from its working directory at launch.
For example, place this in the project root when running Zaza from there:

```ini
[ports.qt]
showFps=1

[shortcutKey]
showFps=Ctrl+F
quit=Esc
```

`showFps=1` starts with the counter visible. The default is `0`. The setting
and section names follow mGBA’s INI conventions. Zaza keeps them in one file.
Shortcuts use physical key names such as `F3`, `X`, and `Left`, with optional
`Ctrl`, `Shift`, `Alt`, and `Meta` (`Cmd` on macOS). An empty shortcut
disables that action’s binding. A matching emulator shortcut takes precedence
over a GBA button on the same key. Toggling affects the current session.

## Operating a game from an agent

Start `zaza-cli session game.gba` as a subprocess and keep its stdin and stdout
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

### Recording and replaying a session

Add `--record` after the ROM to save the session's execution commands to a new
transcript. For example, this session takes a checkpoint, tries one branch,
then restores the checkpoint and tries another.

```sh
printf 'step 2 none\ncheckpoint\nstep 4 Right A\nrestore\nstep 3 Left\nquit\n' |
  zig-out/bin/zaza-cli session game.gba --record attempt.zaza-session
zig-out/bin/zaza-cli replay-session game.gba attempt.zaza-session final.bmp
```

The transcript is published on `quit` or end of input and requires a fresh
path. It contains successful `step`, `checkpoint`, and `restore` commands in
order. `screen` commands and their output paths are omitted. Replay prints one
`ok <current frame>` after verification. Omit the BMP path to verify without
writing an image.

The transcript stores the boot mode, save type, and BLAKE3 digests of the ROM,
BIOS, and starting battery save. Use the same starting data and boot mode when
replaying. If recording can change an existing save, keep a copy from before
the session and pass that copy as `--save` before `replay-session`. If the
session began with empty save memory, omit `--save` for replay and repeat any
`--save-type` override. Replay reads a supplied save without writing back to it.

The format starts with `zaza-session 1`, followed by a `start` line carrying
those fields in this order: boot mode, ROM digest, BIOS digest, save type, save
digest. The final `end` line stores the frame number and a BLAKE3 digest of
row-major RGB bytes, or `unavailable` if the display mode could not be captured.
Replay checks the starting fields and final result before writing the optional
BMP. ROM, BIOS, and save contents stay outside the transcript.

## Headless execution

The same executable can run a complete experiment in one command. Use
`zaza-cli snapshot game.gba 10000 frame.bmp` for an instruction-count snapshot,
`zaza-cli demo frame.bmp` for the built-in cartridge, or `zaza-cli replay` for
frame-indexed input and optional WAV capture. These commands and `session`
work without opening a window or an audio device. Build with
`zig build cli` to omit Mach and retain the same CLI.

```sh
zig build cli
printf '2 A\n18 none\n' > /tmp/zaza-input.txt
zig-out/bin/zaza-cli replay ../ziggba/zig-out/keydemo.gba 20 /tmp/keydemo.bmp \
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
zig-out/bin/zaza-cli --boot replay /path/to/bios.gba 400 /tmp/bios-test.bmp \
  --input '0 none'
```

To select a different BIOS, add `--bios /path/to/bios.bin` before the command.

## Cartridge saves

Zaza detects save hardware from the ROM's save-type signature. Use
`--save-type sram`, `flash64`, `flash128`, `eeprom`, `eeprom512`,
`eeprom8k`, or `none` to override detection. The `eeprom` setting infers
capacity from the game's DMA commands or the size of an existing save.

The macOS player automatically loads and saves battery data for cartridges
with save hardware. Files live under
`~/Library/Application Support/Zaza/Saves/` and are named by the BLAKE3 hash
of the ROM bytes. Renaming or moving a ROM keeps its save. A changed ROM
gets a separate file. Cartridges without save hardware skip this storage.

Use `--save /path/to/game.sav` to choose a specific raw save file. Supply
save options before the command or ROM. In the headless CLI, cartridge save
data stays in memory unless you supply `--save`.

```sh
./zig-out/bin/zaza --save /path/to/game.sav /path/to/game.gba
```

Zaza writes changed data after a successful capture or on normal window
exit, and before switching cartridges in the player. The first successfully
opened ROM uses any `--save` and `--save-type` launch options. Later ROMs use
automatic save-type detection and the default save directory. Zaza rejects a
save whose size does not match the cartridge and uses an adjacent `.lock` file
to prevent two Zaza sessions from writing the same save.

## Silent audio testing

Replay captures both square channels, wave RAM, noise, and Direct Sound A and B
as stereo, signed 16-bit PCM at
32,768 Hz. It writes the WAV on the emulated clock without opening an audio
device. Input is optional. Use fresh output paths for each run.

```sh
zig build cli audio-test-rom
zig-out/bin/zaza-cli replay zig-out/roms/direct-sound.gba 1 /tmp/direct-sound.bmp --wav /tmp/direct-sound.wav
```

The test cartridge sends an ascending ramp to the left channel on timer 0
and a descending ramp at half the rate to the right channel on timer 1.
DMA1 and DMA2 refill the respective FIFOs. `zig build test` checks every
captured sample of the first frame, including signed wraparound and refills.
The first frame runs from cartridge startup to VBlank. Later frames span
a full display period. The WAV contains the digital mix before analog output filtering.
The PSG oscillators, length counters, sweep, and envelopes also advance when
a WAV is not being recorded.

## Filtering log output

The CLI and desktop player read log settings from the working directory's
`zaza.ini` at startup. Messages go to stderr, so session stdout remains
available for the agent protocol. For example, keep host warnings and errors,
show guest messages through info, and silence audio backend diagnostics:

```ini
[ports.qt]
logLevel=7
logLevel.gba.debug=15
logLevel.sysaudio=0
```

Values are mGBA-style bit masks. Add 1 for fatal, 2 for error, 4 for warning,
8 for info, and 16 for debug. Zero silences a category. A category setting
replaces the global mask. The mGBA stub (32) and game-error (64) bits are
accepted for config compatibility; Zaza currently emits neither level.

`gba.debug` selects guest messages from the mGBA debug port. Guest fatal
messages are diagnostics and execution continues. Other names match Zig log
scopes, including `mach`, `sysaudio`, and `default` for unscoped messages.
With no settings, guest messages at every level and the host's normal
build-mode diagnostics are visible. Embedders retain their own root
`std_options` and logging policy.
