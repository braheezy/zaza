# zaza

`zaza` is a Game Boy Advance emulator. It hopes to be:

- **performant**: Run many instances of `zqza` on the same machine, and fast
- **accurate**: Strict timing adherence and cycle tracking
- **embeddable**: `libzaza` holds all emulation logic and thin clients can be created in hundreds of lines of code.

## running

If you wanna run it, you have to build it yourself. Start by getting the project:

```
git clone https://github.com/braheezy/zaza
cd zaza
```

Only requirement is Zig and this project uses [Mach](https://machengine.org/) so you'll need the proper nominated Zig version. [`anyzig`](https://marler8997.github.io/anyzig/) will handle this for you.

```
zig build desktop
./zig-out/bin/zaza <path to rom>
```

For servers and agents, build with `zig build cli` and run
`./zig-out/bin/zaza-cli session <rom>`. See [headless commands](docs/input.md).

## External tests

- [SingleStepTests ARM7TDMI](https://github.com/SingleStepTests/ARM7TDMI) — passing
- [FuzzARM](https://github.com/DenSinH/FuzzARM) - passing
- [Armwrestler GBA fixed](https://github.com/destoer/armwrestler-gba-fixed) - mostly passing
- [gba-tests](https://github.com/jsmolka/gba-tests) - passing
- [mGBA test suite](https://github.com/mgba-emu/suite) - mostlyy passing

See the [hardware verification checklist](docs/hardware-verification.md) for behaviors that still need a physical GBA result.
