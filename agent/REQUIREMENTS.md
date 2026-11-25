# Game Boy Advance Emulator
## Project Requirements Specification

**Status:** Playable macOS emulator, partial hardware conformance  
**Language:** Zig  
**Target platforms:** macOS, Linux, web browsers  
**Graphics:** Mach / native GPU  
**Scope:** Full-featured, accuracy-focused GBA emulation

---

## Implementation status

Checked requirements have working implementations on the current macOS build. An
open box can mean partial support or an unverified acceptance criterion.

- The Mach desktop player and the CLI for scripted replay and persistent agent sessions both consume the public Zig module `libzaza`. Sessions accept button inputs and return framebuffer observations on demand. All modes share the machine, ROM loader, BIOS selection and save handling. The player adds keyboard input, integer-scaled Mach presentation and stereo playback. The runner adds frame-indexed input and BMP/WAV capture.
- Zeleste reaches gameplay and has been played on macOS. This is one homebrew compatibility result. Commercial coverage, Linux desktop support and prolonged stability remain open.
- The recorded fresh-boot mGBA suite runs passed memory (1552/1552), timing (2020/2020), DMA (1244/1244), timer IRQ (90/90) and timer count-up (936/936). Miscellaneous edge cases scored 8/12 in that run. Visual tests were inspected manually. These are historical results, not a per-build certification.
- All four PSG channels and both Direct Sound FIFOs produce samples. Audio accuracy, device selection and synchronization across playback speeds remain open. The GPU presents the software framebuffer. The macOS player supports persistent quick states and three numbered slots. Enhanced rendering, debugger UI and linked multiplayer remain open.

## 1. Project Objectives

Alongside hardware fidelity, Zaza has four product priorities. Agents should be able to operate the shipped emulator directly. Developers using ziggba should get a shorter path from a Zig source change to a verified result. Web applications should be able to embed the same emulation core efficiently. Native hosts should be able to embed the core and own their event loop. Section 15 defines the outcomes for each.

- [ ] **REQ-001 — Competitive emulator**

The application shall be a production-quality Game Boy Advance emulator capable of competing with established emulators including mGBA, NanoBoyAdvance, and SkyEmu in accuracy, compatibility, performance, and features.

- [ ] **REQ-002 — Hardware fidelity**

The emulator shall reproduce observable GBA hardware behavior as accurately as possible, including cycle-level timing interactions.

- [ ] **REQ-003 — Performance**

The emulator shall prioritize efficient execution, low latency, minimal memory overhead, and hardware-accelerated graphics.

- [ ] **REQ-004 — Complete desktop application**

The project shall deliver a polished, standalone desktop application rather than merely an emulation library or command-line frontend.

- [ ] **REQ-005 — Extensibility**

The architecture shall support additional frontends, developer tools, automation, graphics enhancements, and potentially other Nintendo handheld systems without compromising the GBA implementation.

## 2. Language, Dependencies, and Build

- [ ] **REQ-006 — Pure Zig implementation**

All first-party application code, including emulation, rendering orchestration, audio processing, user interface, file handling, networking, and tooling, shall be written in Zig.

- [ ] **REQ-007 — Zig-only dependencies**

All bundled third-party source dependencies, including transitive dependencies, shall be written in Zig. C, C++, Rust, and other native-language runtime libraries shall not be bundled.

- [x] **REQ-008 — System library exception**

Native operating-system APIs, frameworks, graphics drivers, and system-provided libraries may be used through Zig interfaces. These do not violate the Zig-only source requirement.

- [x] **REQ-009 — Mach graphics stack**

The application shall use Mach for its graphics and windowing abstractions, avoiding SDL, Raylib, GLFW, Qt, and conventional cross-platform GUI frameworks.

- [ ] **REQ-010 — GPU shaders**

GPU shader code shall use Zig through Mach's supported shader facilities where possible, without introducing an unrelated shader framework or compiled native-language dependency.

- [ ] **REQ-011 — Zig build system**

The entire project shall use Zig's native build system, with reproducible builds and pinned dependencies.

- [x] **REQ-012 — Native executables**

The application shall produce native executables without requiring a language runtime, interpreter, or development toolchain on the user's machine.

- [ ] **REQ-013 — Dependency transparency**

The project shall maintain an auditable inventory of dependencies, their source languages, licenses, and platform requirements.

## 3. CPU and Hardware Emulation

- [ ] **REQ-014 — ARM7TDMI**

The emulator shall accurately implement the GBA's ARM7TDMI processor, including ARM and Thumb instruction sets.

- [ ] **REQ-015 — CPU execution correctness**

CPU emulation shall reproduce register behavior, processor modes, flags, exceptions, interrupts, pipeline behavior, instruction edge cases, and documented timing.

- [ ] **REQ-016 — CPU optimizations**

The emulator shall support highly optimized execution without sacrificing observable accuracy or deterministic behavior.

- [ ] **REQ-017 — Memory subsystem**

The emulator shall accurately implement the GBA memory map, memory mirroring, access restrictions, alignment behavior, open-bus behavior, and memory wait states.

- [ ] **REQ-018 — Bus timing**

Memory operations shall reproduce access timings, sequential/nonsequential access behavior, cartridge prefetch, and hardware bus contention where observable.

- [ ] **REQ-019 — DMA**

All four DMA channels shall be supported, including transfer modes, priorities, triggers, timing, and interactions with other hardware.

- [ ] **REQ-020 — Timers**

All four hardware timers shall be implemented with accurate prescalers, cascading, overflow behavior, and interrupt generation.

- [ ] **REQ-021 — Interrupt controller**

Interrupt enabling, requesting, servicing, acknowledgement, and timing shall match original hardware behavior.

- [ ] **REQ-022 — System control**

The emulator shall support BIOS calls, software interrupts, HALT, STOP, reset behavior, and power-management-related hardware states.

- [x] **REQ-023 — BIOS compatibility**

The emulator shall support user-provided authentic GBA BIOS images and an independently implemented replacement BIOS where feasible. Authentic BIOS execution shall remain available for maximum fidelity.

- [ ] **REQ-024 — Cycle accuracy**

CPU, PPU, APU, timers, DMA, memory, and interrupts shall operate on a consistent emulated hardware timeline, preserving cycle-level ordering and observable timing interactions.

- [ ] **REQ-025 — Deterministic execution**

Identical initial machine states and input sequences shall produce identical emulated machine states and outputs, independent of host operating system or rendering backend.

## 4. Graphics and GPU Rendering

- [ ] **REQ-026 — Complete PPU emulation**

All six GBA video modes shall be supported, including tiled, affine, and bitmap backgrounds.

- [ ] **REQ-027 — Graphics hardware features**

The renderer shall reproduce sprites, background priorities, transparency, alpha blending, brightness effects, windows, mosaic, affine transformations, and applicable display restrictions.

- [ ] **REQ-028 — Raster accuracy**

The PPU shall reproduce scanline timing, HBlank, VBlank, display-register changes, and observable mid-frame and mid-scanline effects.

- [x] **REQ-029 — Reference rendering**

The emulator shall provide a software-accurate rendering path suitable for validation, testing, and comparison.

- [ ] **REQ-030 — GPU-accelerated rendering**

The application shall provide a hardware-accelerated rendering path capable of reproducing original GBA graphics while exploiting modern GPUs for presentation and enhancements.

- [ ] **REQ-031 — Renderer equivalence**

The accelerated renderer shall produce results equivalent to the reference renderer for supported accuracy modes, with automated detection of rendering discrepancies.

- [x] **REQ-032 — Original display output**

The emulator shall accurately render the original 240×160 display at native resolution, without mandatory filtering, interpolation, or color modification.

- [ ] **REQ-033 — High-resolution graphics**

The renderer shall support enhanced internal resolutions for eligible graphics, preserving correct ordering, transparency, and game effects. Unsupported enhancements shall fall back to accurate rendering without corrupting the image.

- [ ] **REQ-034 — Scaling**

Integer scaling, fractional scaling, nearest-neighbor, and high-quality filtered scaling shall be supported.

- [ ] **REQ-035 — Shader effects**

The application shall support configurable post-processing effects, including LCD simulation, pixel-grid effects, color correction, sharpness enhancement, and CRT-inspired filters.

- [ ] **REQ-036 — Color reproduction**

The application shall support selectable display profiles approximating original GBA and GBA SP screen characteristics, including appropriate color and gamma adjustments.

- [ ] **REQ-037 — Advanced display features**

The renderer shall support adjustable aspect ratio, borderless fullscreen, synchronized presentation, and modern high-DPI displays.

- [ ] **REQ-038 — Extensible graphics effects**

Users shall be able to select, configure, save, and combine supported rendering effects through a reusable preset system.

## 5. Audio

- [ ] **REQ-039 — Complete APU emulation**

The emulator shall accurately reproduce the GBA audio subsystem, including its four legacy programmable sound channels and two Direct Sound channels.

- [ ] **REQ-040 — Audio timing**

Sound registers, DMA-driven samples, timers, mixing, and channel behavior shall be synchronized with the emulated hardware timeline.

- [ ] **REQ-041 — Audio output**

The application shall provide low-latency stereo output with configurable output devices, volume, and quality-preserving sample-rate conversion.

- [ ] **REQ-042 — Audio synchronization**

Audio shall remain synchronized with gameplay across normal speed, fast-forward, slowdown, pausing, and supported display refresh rates.

- [ ] **REQ-043 — Audio enhancements**

The application shall support configurable audio filtering, channel muting, and separate channel inspection without modifying the underlying emulation state.

- [x] **REQ-044 — Audio capture**

The application shall support recording audio output in a lossless format.

## 6. Cartridges, Saves, and Peripherals

- [ ] **REQ-045 — Cartridge compatibility**

The emulator shall support standard commercial GBA cartridges, homebrew applications, and ROM images using supported cartridge layouts.

- [ ] **REQ-046 — Save hardware**

SRAM, EEPROM, and Flash save hardware shall be accurately emulated, including relevant sizes, command protocols, and timing.

- [x] **REQ-047 — Save detection**

Cartridge save hardware shall be detected automatically where possible, with manual overrides for ambiguous titles.

- [x] **REQ-048 — Persistent saves**

Battery-backed saves shall persist independently of emulator save states, with protections against corruption or accidental overwriting.

- [ ] **REQ-049 — Real-time clock**

Cartridge-based real-time clocks shall be supported, including configurable clock behavior for deterministic execution.

- [ ] **REQ-050 — Cartridge sensors**

The emulator shall support cartridge peripherals including solar sensors, tilt sensors, accelerometers, gyroscopes, and rumble where applicable.

- [ ] **REQ-051 — Specialized cartridges**

Supported cartridge-specific devices and behaviors shall include commercially relevant accessories and custom hardware, such as the BattleChip Gate.

- [ ] **REQ-052 — ROM patching**

The emulator shall support common patch formats, including IPS, UPS, and BPS, without requiring modification of the original ROM.

- [ ] **REQ-053 — External BIOS and ROM ownership**

The application shall not redistribute proprietary BIOS images, commercial ROMs, or copyrighted game assets without authorization.

## 7. Gameplay and Emulator Features

- [ ] **REQ-054 — Save states**

Users shall be able to create, name, organize, load, and delete arbitrary emulator save states.

- [ ] **REQ-055 — State portability**

Save states shall use a documented, versioned format with compatibility validation and backward compatibility across releases where practical.

- [ ] **REQ-056 — Rewind**

The emulator shall support configurable real-time rewind with a navigable history of recent gameplay.

- [ ] **REQ-057 — Fast-forward and slowdown**

Users shall be able to adjust emulation speed independently of the host display refresh rate.

- [ ] **REQ-058 — Frame advance**

The emulator shall support advancing execution by individual frames while paused.

- [ ] **REQ-059 — Run-ahead**

The emulator shall support configurable input-latency reduction through speculative execution, without altering committed emulation state.

- [ ] **REQ-060 — Input configuration**

Keyboard and game controllers shall support configurable bindings, profiles, hot-plugging, shortcuts, turbo inputs, and remapping.

- [ ] **REQ-061 — Input recording**

The emulator shall support deterministic input recording and playback, including frame-exact reproduction where the initial machine state and configuration are identical.

- [ ] **REQ-062 — Screenshots and recordings**

Users shall be able to capture native-resolution screenshots, processed screenshots, and lossless gameplay recordings.

- [ ] **REQ-063 — Cheats**

The emulator shall support memory-based cheats, memory freezing, and established GBA cheat-code formats where legally and technically applicable.

- [ ] **REQ-064 — Per-game configuration**

Games shall support independent settings for saves, controls, graphics, audio, emulation compatibility, and enhancements.

- [ ] **REQ-065 — Game identification**

The application shall identify games using cartridge metadata and hashes, preserving compatibility across alternate regions and revisions.

- [ ] **REQ-066 — Error recovery**

Unexpected ROM behavior, malformed files, unsupported peripherals, and recoverable emulation errors shall not unnecessarily terminate the desktop application.

## 8. Multiplayer and Connectivity

- [ ] **REQ-067 — Link cable**

The emulator shall implement GBA serial communication and link-cable modes with hardware-accurate observable behavior.

- [ ] **REQ-068 — Local multiplayer**

The application shall support multiple linked GBA instances on one host, including multiplayer configurations supporting up to four players where applicable.

- [ ] **REQ-069 — Network multiplayer**

Linked systems shall be capable of communicating across a network with synchronization and recovery mechanisms appropriate to the emulated protocol.

- [ ] **REQ-070 — Wireless Adapter**

The emulator shall support the GBA Wireless Adapter and games that depend on its communication behavior.

- [ ] **REQ-071 — Multiplayer determinism**

Linked sessions shall preserve correct hardware ordering and deterministic outcomes under equivalent inputs and communication events.

- [ ] **REQ-072 — Multiboot**

The emulator shall support GBA multiboot behavior and compatible software transfers through emulated communication interfaces.

## 9. Desktop User Interface

- [ ] **REQ-073 — Platform support**

The desktop application shall support macOS on Apple Silicon and Intel, and Linux on x86-64 and ARM64 where the required graphics capabilities are available.

- [ ] **REQ-074 — Linux display servers**

The application shall support both Wayland and X11 environments.

- [ ] **REQ-075 — Native appearance**

The UI shall follow modern platform conventions for typography, window behavior, controls, menus, keyboard shortcuts, and visual layout without requiring native widget frameworks.

- [ ] **REQ-076 — Custom Zig GUI**

The user interface shall be implemented in Zig using the project's permitted rendering and platform abstractions.

- [ ] **REQ-077 — Theme support**

The application shall support light and dark themes, automatic system-theme selection, and configurable appearance.

- [ ] **REQ-078 — Game library**

The application shall provide a browsable game library with search, filtering, sorting, favorites, recently played games, and optional cover art and metadata.

- [ ] **REQ-079 — Game management**

Game-specific saves, states, settings, screenshots, recordings, and metadata shall be accessible through a unified interface.

- [ ] **REQ-080 — Session management**

Users shall be able to resume sessions, launch games directly, switch games, and manage multiple emulation instances.

- [ ] **REQ-081 — Controller-first usability**

Core gameplay and library operations shall remain usable with a controller without requiring a mouse.

- [ ] **REQ-082 — High-DPI UI**

The interface shall remain sharp and readable on Retina and other high-density displays, with scalable interface elements.

- [ ] **REQ-083 — Accessibility**

The application shall support keyboard navigation, appropriate contrast, adjustable text scaling, and relevant OS accessibility integrations.

- [ ] **REQ-084 — OS integration**

The application shall support native file dialogs, drag-and-drop ROM loading, file associations, system menus, and platform-appropriate application behavior.

- [ ] **REQ-085 — Configuration persistence**

Application and per-game preferences shall persist across sessions using a documented, portable configuration format.

## 10. Debugging and Developer Tools

- [ ] **REQ-086 — Integrated debugger**

The application shall provide a debugger capable of inspecting CPU registers, disassembly, stack, memory, and active execution state.

- [ ] **REQ-087 — Execution control**

The debugger shall support breakpoints, conditional breakpoints, memory watchpoints, instruction stepping, frame stepping, and execution tracing.

- [ ] **REQ-088 — Memory inspection**

Users shall be able to inspect, search, compare, and modify emulated memory, including changes across frames or save states.

- [ ] **REQ-089 — Graphics inspection**

The application shall expose backgrounds, tiles, tilemaps, sprite attributes, palettes, VRAM, OAM, and graphics registers through interactive viewers.

- [ ] **REQ-090 — Audio inspection**

The debugger shall expose individual sound-channel states, audio registers, generated waveforms, and timing information.

- [ ] **REQ-091 — Hardware timeline**

The application shall provide a synchronized visualization of CPU execution, DMA transfers, interrupts, timers, PPU activity, and other emulated hardware events.

- [ ] **REQ-092 — Reverse debugging**

The debugger shall support restoring and inspecting recent execution history, including reverse stepping where sufficient state history is available.

- [ ] **REQ-093 — Profiling**

The emulator shall expose CPU hot paths, emulated instruction counts, performance bottlenecks, GPU workloads, and frame-time measurements.

- [x] **REQ-094 — Headless execution**

The emulator shall operate without a graphical interface for automated tests, scripted execution, benchmarking, and external tooling.

- [ ] **REQ-095 — Programmatic interface**

The emulation core shall expose a documented Zig API for machine control, input injection, memory access, state capture, and event observation.

- [ ] **REQ-096 — Automation**

Developers shall be able to execute ROMs with predefined inputs and collect reproducible outputs, memory snapshots, screenshots, and diagnostic traces.

## 11. Novel Features

- [ ] **REQ-097 — Interactive execution history**

The application shall provide a navigable execution history connecting gameplay frames, input events, save states, and relevant hardware events.

- [ ] **REQ-098 — Hardware visualization**

Users shall be able to visualize the operation of the emulated console, including graphics composition, memory activity, CPU state, and sound generation in real time.

- [ ] **REQ-099 — Renderer comparison**

The application shall support pixel-level comparisons between reference and accelerated rendering, including difference visualization.

- [ ] **REQ-100 — State comparison**

Users shall be able to compare two saved machine states and inspect differences in registers, memory, graphics, and hardware configuration.

- [ ] **REQ-101 — Reproducible bug reports**

The application shall support exporting portable diagnostic bundles containing relevant settings, logs, input recordings, state captures, and execution metadata without automatically including copyrighted ROM or BIOS data.

- [ ] **REQ-102 — Shareable gameplay artifacts**

Users shall be able to export and import compatible input recordings, rendering presets, and emulator configurations.

- [ ] **REQ-103 — Library analytics**

The game library shall track optional local statistics including playtime, sessions, last played, and completion status.

- [ ] **REQ-104 — Extensible tooling**

The project shall expose stable interfaces allowing external utilities to inspect or control emulation without modifying the core.

## 12. Performance and Reliability

- [ ] **REQ-105 — Full-speed execution**

The emulator shall sustain the GBA's native operating speed and approximately 59.73 Hz video cadence on supported baseline hardware, including demanding commercial games.

- [ ] **REQ-106 — Performance headroom**

The emulation core shall support substantially faster-than-real-time execution when uncapped, targeting at least 10× native speed in headless benchmarks on representative supported desktop hardware. For agents exploring a game at uncapped speed, the goal is to beat PyBoy in emulated seconds per wall-clock second on the same host. Compare representative workloads for each console with matched input and observation intervals, and record the ROMs, emulator versions, and audio and video settings.

- [ ] **REQ-107 — Frame pacing**

The application shall minimize frame-time variance, visual stuttering, unnecessary frame duplication, and audio/video drift.

- [ ] **REQ-108 — Input latency**

The application shall minimize host-side input-to-display latency and offer configurable synchronization options appropriate to high-refresh-rate displays.

- [ ] **REQ-109 — Resource efficiency**

Normal gameplay shall avoid excessive memory allocation, redundant frame copies, unnecessary GPU synchronization, and avoidable background CPU usage. An agent shall be able to branch from a checkpoint and run many independent instances on one machine. Keep CPU time per emulated frame and incremental memory per instance low so more branches can advance within a fixed CPU and memory budget.

- [ ] **REQ-110 — Memory safety**

The application shall enforce explicit memory ownership and lifecycle management, with automated checks for leaks, invalid accesses, and resource lifetime errors.

- [ ] **REQ-111 — Concurrency**

Concurrent rendering, audio, input, and emulation activities shall not introduce races, nondeterministic emulation results, or corrupted machine states.

- [ ] **REQ-112 — Long-running stability**

The application shall remain stable during prolonged gameplay, repeated save/load operations, ROM changes, display resizing, and suspend/resume cycles.

- [ ] **REQ-113 — GPU resilience**

The application shall handle graphics-device initialization failures, device loss, and unsupported GPU capabilities gracefully.

- [ ] **REQ-114 — Battery and idle efficiency**

The application shall avoid unnecessary GPU and CPU workloads while paused, minimized, or idle.

## 13. Accuracy, Compatibility, and Testing

- [ ] **REQ-115 — Hardware conformance**

The emulator shall target complete passing results on applicable publicly available GBA hardware test suites, including GBA Suite, Armwrestler, and FuzzARM.

- [ ] **REQ-116 — Commercial compatibility**

The emulator shall target at least 99% playable compatibility across a documented, representative commercial GBA test library, with separate reporting of boot, gameplay, graphical, audio, and completion defects.

- [ ] **REQ-117 — Homebrew compatibility**

The emulator shall support hardware-compliant homebrew software, demos, and diagnostic ROMs without commercial-game-specific assumptions.

- [ ] **REQ-118 — Regression testing**

Previously verified hardware behaviors and game compatibility results shall be protected by automated regression tests.

- [ ] **REQ-119 — Differential validation**

The project shall support comparing deterministic execution results against trusted emulator references and documented real-hardware captures.

- [ ] **REQ-120 — Hardware verification**

Timing-sensitive behavior and emulator discrepancies shall be evaluated against real GBA hardware evidence when available.

- [ ] **REQ-121 — Cross-platform consistency**

Emulated machine behavior shall be identical across supported operating systems and CPU architectures for equivalent configurations.

- [ ] **REQ-122 — Compatibility database**

The project shall maintain a versioned compatibility database containing tested games, revisions, hardware requirements, known issues, and verification results.

- [ ] **REQ-123 — Fuzz testing**

ROM parsing, save-state loading, instruction decoding, memory access, cartridge handling, and other relevant inputs shall be subject to automated robustness testing.

- [ ] **REQ-124 — Performance regression testing**

CPU performance, rendering throughput, startup time, memory consumption, and frame pacing shall be benchmarked against reproducible baselines. For branching workloads, report aggregate emulated seconds per wall-clock second and peak resident memory as the number of concurrent instances increases on a fixed host.

## 14. Distribution and Project Quality

- [ ] **REQ-125 — Open source**

The project shall be openly developed and distributed under a license compatible with its dependency and contribution policies.

- [ ] **REQ-126 — Native distribution**

The application shall provide platform-appropriate downloadable builds and installation packages for supported macOS and Linux targets.

- [x] **REQ-127 — Self-contained installation**

End users shall not need to install Zig, Mach, an SDK, or a development toolchain to run the application.

- [ ] **REQ-128 — Portable configuration**

Users shall be able to relocate or back up their game library metadata, saves, recordings, states, and configuration without proprietary cloud services.

- [ ] **REQ-129 — Local-first operation**

All core emulation, local multiplayer, library management, debugging, and gameplay functionality shall operate without an internet connection.

- [x] **REQ-130 — Privacy**

The application shall not collect telemetry, upload ROM contents, or transmit user data without explicit user consent.

- [ ] **REQ-131 — Documentation**

The project shall maintain user-facing documentation, supported-platform information, compatibility data, and technical documentation for its public interfaces.

- [ ] **REQ-132 — Reproducibility**

Official builds shall identify their source revision, Zig toolchain version, dependency versions, and relevant build configuration.

- [ ] **REQ-133 — Feature parity**

The completed product shall offer a competitive superset of the most useful established GBA emulator capabilities, combining hardware fidelity, gameplay enhancements, peripheral compatibility, developer tooling, and modern desktop usability in a single application.

## 15. Agent, ziggba, and web integration

- [ ] **REQ-134 — First-class agent operation**

The released application shall expose a documented, stable interface for an agent to start a ROM, observe the screen, apply GBA buttons for an exact number of frames, and inspect the result in the same session. Emulated time shall wait while the agent decides. An evaluation harness shall be able to record the inputs and starting configuration so another user can reproduce the attempt. The existing `zaza-cli session` and `zaza-cli replay` commands provide the initial implementation.

- [ ] **REQ-135 — First-class ziggba development workflow**

Zaza shall integrate with ziggba so a developer can build a ROM, launch that build, and verify a gameplay change from the project's normal Zig workflow. The goal is a demonstrably better edit–run–debug cycle than opening the same ROM in a general-purpose emulator. Evaluate the integration on a representative ziggba project by comparing the steps to reproduce a bug and identify the responsible Zig code. Build-step integration and use of compiler debug information are candidate designs. SDK conveniences shall preserve the hardware behavior seen by the ROM.

- [ ] **REQ-136 — Efficient web embedding**

A web application shall be able to embed Zaza, load a user-supplied ROM, deliver controller input, and present video and audio using the same emulation core as the desktop player. Optimize against measurements from a representative embedded game, including download size, time to the first playable frame, frame pacing, and audio underruns. WebAssembly is the leading candidate. The packaging, browser APIs, and performance targets remain open design decisions.

- [x] **REQ-137 — Native Zig embedding**

A Zig host can import libzaza, supply in-memory cartridge and BIOS images, advance frames from button state, consume RGB frames and PCM, and manage saves and in-process checkpoints. The CLI and desktop player use that interface. The host owns presentation, storage and pacing. See [Embedding libzaza](../docs/embedding.md).
