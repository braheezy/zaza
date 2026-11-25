# Hardware verification checklist

For each result, record the console model, exact ROM build, and observed output. A published hardware capture can also settle an item if it exercises the same case.

- [ ] **Reserved Thumb branch (`0xDExx`).** Zaza takes the signed PC-relative branch and preserves CPSR, matching the NanoBoyAdvance-generated SingleStep vectors. Run a Thumb ROM that seeds different N/Z/C/V combinations and uses a raw `0xDE01` to skip a distinct fall-through marker. Save the path and flags before any flag-setting instruction at either destination. [Vector provenance](../test/CPU-TEST-RESOURCES.md)
- [ ] **Text-background open bus in ziggba’s tileDemo.** Zaza models a shared halfword latch for text fetches. Run the original demo and a minimal Mode 0 case with distinct tile patterns on two layers and an out-of-range tile fetch. Record which pattern appears when the layers exchange fetch order. This checks the source of the returned pixels where emulators disagree.
- [ ] **SM64 benchmark frame hits.** Run the same adaptive-quality tour used for the emulator comparisons. Record the ROM hash, frame-hit count, percentage, and any reported quality setting. A hardware result gives a reference for the small difference seen between Zaza and NanoBoyAdvance.
- [ ] **Held-key IRQ retrigger and STOP wake.** Hold a selected key, acknowledge keypad IF, and record whether IF reasserts before release. In a separate run, enter STOP and apply the selected key combination. Record whether the CPU resumes and which IRQ flags are set.
- [ ] **VCOUNT reads at VBlank IRQ entry.** Bad Apple polls line 160 before doing enough video DMA in its IRQ handler to outlast VBlank. Run the [Thumb polling probe](../test/vblank-poll/probe.S) on a GBA and photograph the eight result rows. Each row starts polling on line 159 with a different delay. Read the 16 bits left to right, white for one. The first byte is the last VCOUNT read and the second is the byte offset of the instruction that resumes after IRQ, relative to the polling load. Record the BIOS and boot path alongside the ROM hash. Zaza currently uses mGBA’s seven-cycle delay for VBlank IRQ delivery. Individual probe trials still disagree; exact hardware timing remains open.

  To build the probe from the repository root, supply a local bootable GBA cartridge for its standard header logo. These commands use Clang with ARM support and Zig.

  ```sh
  clang --target=armv4t-none-eabi -DHEADER_ROM='"test/roms/first.gba"' -c test/vblank-poll/probe.S -o /tmp/vblank-poll.o
  zig objcopy -O binary -j .text /tmp/vblank-poll.o /tmp/vblank-poll.gba
  ```
