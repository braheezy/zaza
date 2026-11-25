const std = @import("std");
const mach = @import("mach");
const objc = @import("objc");
const gpu = mach.gpu;
const cartridge = @import("cartridge.zig");
const video = @import("libzaza").video;
const Playback = @import("desktop_audio.zig");
const Machine = @import("libzaza").Emulator;
const input = @import("libzaza").input;
const Config = @import("desktop_config.zig");
const Store = @import("state_file.zig");
const Menu = @import("macos_menu.zig");
const SaveFile = @import("save_file.zig");
const SaveSession = SaveFile.Session;
const Fps = @import("fps.zig");

const frame_period_ns = @import("libzaza").frame_period_ns;
const window_scale = 3;
const window_width = video.width * window_scale;
const window_height = video.height * window_scale;
const black: video.Rgb = .{ .red = 0, .green = 0, .blue = 0 };

const Modules = mach.Modules(.{ mach.Core, App });
const Storage = struct { states: []const u8, saves: []const u8 };

pub fn play(init: std.process.Init, options: cartridge.Options, path: ?[]const u8, volume: u8) !void {
    const arena = init.arena.allocator();
    const config = Config.load(init.io, arena) catch |err| {
        std.log.err("loading zaza.ini: {s}", .{@errorName(err)});
        return err;
    };
    var playback: Playback = undefined;
    var live_audio: ?*Playback = null;
    defer if (live_audio) |audio| audio.deinit();
    if (volume != 0) {
        if (playback.init(init.gpa, volume)) {
            live_audio = &playback;
        } else |err| std.log.warn("audio output unavailable ({s}), continuing muted", .{@errorName(err)});
    }

    var modules: Modules = undefined;
    try modules.init(init.gpa, init.io);
    defer modules.deinit(init.gpa);
    const app = &modules.mods.app;
    const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
    const data_root = try std.fs.path.join(arena, &.{ home, "Library/Application Support/Zaza" });
    const storage: Storage = .{
        .states = try std.fs.path.join(arena, &.{ data_root, "States" }),
        .saves = try std.fs.path.join(arena, &.{ data_root, "Saves" }),
    };
    app.* = .{ .storage = storage, .options = options, .audio = live_audio, .config = config };
    if (path) |initial| {
        const loaded = try Game.load(init.gpa, init.io, initial, options, live_audio, storage, null);
        app.game = loaded.game;
        app.options.save = .{};
    }
    defer if (app.game) |*game| game.deinit(init.io);
    modules.get(.app).run(.main);
    if (modules.mods.app.failure) |err| return err;
}

// Each cartridge owns the storage borrowed by its emulator, including an optional custom BIOS.
const Game = struct {
    arena: std.heap.ArenaAllocator,
    machine: *Machine,
    save: ?SaveSession,
    title: [:0]const u8,
    paused: bool = false,
    states: Store,
    refresh_frame: bool = false,
    first_frame: bool = true,

    const Loaded = struct { game: Game, reused_save: ?SaveSession = null };

    fn load(
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        options: cartridge.Options,
        audio: ?*Playback,
        storage: Storage,
        previous_save: ?SaveSession,
    ) !Loaded {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const rom = try cartridge.loadRom(io, allocator, path);
        const title = try std.fmt.allocPrintSentinel(allocator, "Zaza — {s}", .{std.fs.path.basename(path)}, 0);
        const machine = try allocator.create(Machine);
        try machine.init(rom, try options.emulatorOptions(io, allocator));
        const save_memory = machine.saveMemory();
        const kind = options.save.kind orelse save_memory.kind;
        save_memory.kind = kind;
        const states = try Store.init(allocator, io, storage.states, machine, kind);
        if (audio) |playback| machine.setAudioCapture(&playback.capture);
        var game: Game = .{
            .arena = arena,
            .machine = machine,
            .save = null,
            .title = title,
            .states = states,
        };
        var save_options = options.save;
        if (save_options.path == null and kind != .none) {
            const directory = try std.Io.Dir.cwd().createDirPathOpen(io, storage.saves, .{});
            defer directory.close(io);
            var digest: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(rom, &digest, .{});
            save_options.path = try std.fmt.allocPrint(allocator, "{s}/{x}.sav", .{
                storage.saves, &digest,
            });
        }
        if (previous_save) |session| {
            if (save_options.path) |save_path| {
                if (std.mem.eql(u8, session.path, save_path)) {
                    const reused = try session.reload(io, allocator, save_path, save_memory);
                    return .{ .game = game, .reused_save = reused };
                }
            }
        }
        game.save = try save_options.open(io, allocator, save_memory);
        return .{ .game = game };
    }

    fn flush(self: *Game, io: std.Io) !void {
        if (self.save) |*session| try session.flush(io, self.machine.saveMemory());
    }

    fn deinit(self: *Game, io: std.Io) void {
        if (self.save) |session| session.close(io);
        self.arena.deinit();
    }
};

const App = struct {
    pub const mach_module = .app;
    pub const mach_systems = .{ .main, .init, .tick, .pollInput, .emulate, .publish, .render, .deinit };
    pub const main = mach.schedule(.{
        .{ mach.Core, .init },
        .{ App, .init },
        .{ mach.Core, .main },
    });
    pub const tick = mach.schedule(.{
        .{ App, .pollInput },
        .{ App, .emulate },
        .{ mach.Core, .snapshotStart },
        .{ App, .publish },
        .{ mach.Core, .snapshotEnd },
    });

    menu: Menu = undefined,
    config: Config,
    storage: Storage,
    options: cartridge.Options,
    game: ?Game = null,
    // AppKit replaces the cartridge on the main thread, between emulation frames.
    game_mutex: std.Io.Mutex = .init,
    core: *mach.Core = undefined,
    window_id: mach.ObjectID = undefined,
    display_fps: bool = false,
    audio: ?*Playback,
    failure: ?anyerror = null,
    frame: video.Frame = @splat(@splat(black)),
    app_thread: mach.Thread = undefined,
    renderer: ?Renderer = null,
    keys: input.LiveKeys = .{},
    next_frame_ns: ?i96 = null,
    pending: ?video.Frame = null,
    frame_revision: u64 = 0,

    pub fn init(
        app: *App,
        core: *mach.Core,
        app_mod: mach.Mod(App),
        core_mod: mach.Mod(mach.Core),
        io: std.Io,
    ) !void {
        app.core = core;
        core.on_exit = app_mod.id.deinit;
        const window_id = try core.windows.new(.{
            .title = if (app.game) |game| game.title else "Zaza — Open ROM (⌘O)",
            .width = window_width,
            .height = window_height,
            .on_render = app_mod.id.render,
        });
        // Create the AppKit window and set its constraints on the main thread
        // before starting the input and emulation thread.
        try core.tick(core_mod, io);
        const window = blk: {
            core.windows.lockShared();
            defer core.windows.unlockShared();
            const native = core.windows.get(window_id, .native) orelse return error.WindowNotCreated;
            break :blk native.window;
        };
        app.window_id = window_id;
        lockWindowSize(window);
        app.menu = try Menu.install(app, performCommand);
        app.menu.updateStates(if (app.game) |game| game.states.occupied else null);
        app.menu.updatePause(app.game != null, false);
        app.app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app);
    }

    fn performCommand(app: *App, action: Menu.Action, slot: usize) void {
        switch (action) {
            .save_state, .load_state, .delete_state => {
                const game = if (app.game) |*current| current else return;
                if (action == .delete_state and !Menu.confirmChange("Delete", slot)) return;
                if (action == .save_state and slot != 0 and game.states.occupied[slot] and
                    !Menu.confirmChange("Replace", slot)) return;
                app.stateCommand(action, slot) catch |err| Menu.showError("State operation failed", game.title, err);
            },
            .quit => app.core.exit(),
            .toggle_pause => {
                app.game_mutex.lockUncancelable(app.core.io);
                defer app.game_mutex.unlock(app.core.io);
                const game = if (app.game) |*current| current else return;
                game.paused = !game.paused;
                app.menu.updatePause(true, game.paused);
            },
            .open_rom => {
                const path = Menu.chooseRom() orelse return;
                app.openRom(path) catch |err| Menu.showError("Couldn’t open the ROM", path, err);
            },
        }
    }

    fn stateCommand(app: *App, action: Menu.Action, slot: usize) !void {
        const core = app.core;
        app.game_mutex.lockUncancelable(core.io);
        defer app.game_mutex.unlock(core.io);
        const game = &app.game.?;
        switch (action) {
            .save_state => try game.states.save(core.allocator, core.io, slot, game.machine),
            .load_state => {
                try game.states.load(core.allocator, core.io, slot, game.machine);
                if (app.audio) |audio| audio.discardQueued();
                game.refresh_frame = true;
            },
            .delete_state => try game.states.remove(core.io, slot),
            else => unreachable,
        }
        app.menu.updateStates(game.states.occupied);
        const status = switch (action) {
            .save_state => "saved",
            .load_state => "loaded",
            .delete_state => "deleted",
            else => unreachable,
        };
        core.windows.lock();
        defer core.windows.unlock();
        if (slot == 0) try core.fmtTitle(app.window_id, "{s} · Quick state {s}", .{ game.title, status }) else try core.fmtTitle(app.window_id, "{s} · Slot {d} {s}", .{ game.title, slot, status });
    }

    fn openRom(app: *App, path: []const u8) !void {
        const core = app.core;
        app.game_mutex.lockUncancelable(core.io);
        defer app.game_mutex.unlock(core.io);
        const previous_save = if (app.game) |*current| previous: {
            try current.flush(core.io);
            break :previous current.save;
        } else null;
        const loaded = try Game.load(
            core.allocator,
            core.io,
            path,
            app.options,
            app.audio,
            app.storage,
            previous_save,
        );
        var next = loaded.game;
        errdefer next.deinit(core.io);
        {
            core.windows.lock();
            defer core.windows.unlock();
            try core.fmtTitle(app.window_id, "{s}", .{next.title});
        }
        if (loaded.reused_save) |session| {
            // The active cartridge owns the lock until the replacement is ready.
            app.game.?.save = null;
            next.save = session;
        }
        if (app.game) |*current| current.deinit(core.io);
        app.game = next;
        app.menu.updateStates(next.states.occupied);
        app.menu.updatePause(true, false);
        // Explicit save options belong to the first successfully opened cartridge.
        app.options.save = .{};
    }

    pub fn pollInput(app: *App, core: *mach.Core) void {
        var events = core.events(.default);
        while (events.next()) |event| {
            switch (event) {
                .close => core.exit(),
                .focus_lost => app.keys = .{},
                .key_press => |key| if (shortcutAction(&app.config, key.key, key.mods)) |action| {
                    switch (action) {
                        .quit => core.exit(),
                        .showFps => app.config.show_fps = !app.config.show_fps,
                    }
                } else if (mappedButton(key.key)) |button| {
                    app.keys.press(button);
                },
                .key_release => |key| if (mappedButton(key.key)) |button| app.keys.release(button),
                else => {},
            }
        }
        if (core.outOfMemory()) app.keys = .{};
    }

    pub fn emulate(app: *App, core: *mach.Core, io: std.Io) void {
        if (app.failure != null or core.state.load(.acquire) != .running) return;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        const deadline_ns = app.next_frame_ns orelse now_ns;
        if (now_ns < deadline_ns) return;
        // Keep the cadence despite polling jitter, but avoid an unbounded backlog.
        app.next_frame_ns = @max(now_ns, deadline_ns + frame_period_ns);
        app.game_mutex.lockUncancelable(io);
        defer app.game_mutex.unlock(io);
        const game = if (app.game) |*current| current else return;
        if (game.refresh_frame) {
            game.refresh_frame = false;
            app.keys.pressed_since_sample = 0;
            var restored: video.Frame = undefined;
            game.machine.snapshotFrame(&restored) catch {
                restored = @splat(@splat(black));
            };
            app.pending = restored;
            return;
        }
        if (game.paused) return;
        if (game.first_frame) {
            app.keys = .{};
            game.first_frame = false;
        }
        const machine = game.machine;
        machine.runFrame(app.keys.sample()) catch |err| {
            std.log.err("live emulation stopped at 0x{x:0>8}", .{machine.instructionAddress()});
            app.failure = err;
            core.exit();
            return;
        };
        if (app.audio) |audio| {
            if (audio.capture.failure) |err| {
                app.failure = err;
                core.exit();
                return;
            }
            audio.publish();
        }
        var next_frame: video.Frame = undefined;
        machine.snapshotFrame(&next_frame) catch {
            // Startup may run for several VBlanks before selecting a bitmap mode.
            next_frame = @splat(@splat(black));
        };
        app.pending = next_frame;
    }

    pub fn publish(app: *App) void {
        app.display_fps = app.config.show_fps;
        if (app.pending) |next_frame| {
            app.frame = next_frame;
            app.pending = null;
            app.frame_revision +%= 1;
        }
    }

    pub fn render(app: *App, core: *mach.Core, io: std.Io) void {
        const window = core.windows.getValue(core.window);
        if (app.renderer == null) {
            app.renderer = Renderer.init(window.device, window.framebuffer_format);
        }
        const renderer = &app.renderer.?;
        const target = window.swap_chain.getCurrentTextureView() orelse return;
        defer target.release();
        const new_frame = renderer.uploaded_revision != app.frame_revision;
        renderer.fps.tick(std.Io.Clock.awake.now(io).nanoseconds, new_frame and app.frame_revision != 0);
        if (new_frame or renderer.overlay_enabled != app.display_fps or
            (app.display_fps and renderer.uploaded_fps != renderer.fps.tenths))
        {
            renderer.upload(window.queue, &app.frame, app.display_fps);
            renderer.uploaded_revision = app.frame_revision;
            renderer.overlay_enabled = app.display_fps;
            renderer.uploaded_fps = renderer.fps.tenths;
        }
        const encoder = window.device.createCommandEncoder(&.{});
        defer encoder.release();
        const pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .color_attachments = &.{.{
                .view = target,
                .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .load_op = .clear,
                .store_op = .store,
            }},
        }));
        defer pass.release();
        const scale = @min(window.framebuffer_width / video.width, window.framebuffer_height / video.height);
        if (scale != 0) {
            const width = scale * video.width;
            const height = scale * video.height;
            pass.setViewport(
                @floatFromInt((window.framebuffer_width - width) / 2),
                @floatFromInt((window.framebuffer_height - height) / 2),
                @floatFromInt(width),
                @floatFromInt(height),
                0,
                1,
            );
            pass.setPipeline(renderer.pipeline);
            pass.setBindGroup(0, renderer.bind_group, &.{});
            pass.draw(3, 1, 0, 0);
        }
        pass.end();
        const command = encoder.finish(&.{});
        defer command.release();
        window.queue.submit(&.{command});
    }

    pub fn deinit(app: *App, io: std.Io) !void {
        app.app_thread.join();
        // Mach exits the process after this callback, so publish SRAM here.
        if (app.game) |*game| {
            try game.flush(io);
            game.deinit(io);
            app.game = null;
        }
        if (app.renderer) |renderer| {
            renderer.bind_group.release();
            renderer.pipeline.release();
            renderer.texture.release();
        }
    }
};

fn lockWindowSize(window: *objc.app_kit.Window) void {
    // Mach's decorated windows are resizable in this version. Keep the title
    // bar so the window can take keyboard focus and be moved normally.
    const send = objc.objc.msgSend;
    const style = send(window, "styleMask", objc.app_kit.WindowStyleMask, .{});
    send(window, "setStyleMask:", void, .{style & ~objc.app_kit.WindowStyleMaskResizable});
    const size: objc.app_kit.Size = .{ .width = window_width, .height = window_height };
    send(window, "setContentMinSize:", void, .{size});
    send(window, "setContentMaxSize:", void, .{size});
    send(window, "setContentSize:", void, .{size});
    const content = window.contentRectForFrameRect(window.frame()).size;
    std.debug.assert(content.width == size.width);
    std.debug.assert(content.height == size.height);
}

fn shortcutAction(config: *const Config, key: mach.Core.KeyButtonID, mods: mach.Core.KeyMods) ?Config.Action {
    const physical: Config.Key = switch (key) {
        inline else => |button| @field(Config.Key, @tagName(button)),
    };
    return config.action(physical, .{ .ctrl = mods.control, .shift = mods.shift, .alt = mods.alt, .meta = mods.super });
}

fn mappedButton(key: mach.Core.KeyButtonID) ?input.Button {
    return switch (key) {
        .x => .a,
        .z => .b,
        .left_shift => .select,
        .enter => .start,
        .right => .right,
        .left => .left,
        .up => .up,
        .down => .down,
        .s => .r,
        .a => .l,
        else => null,
    };
}

const Renderer = struct {
    pipeline: *gpu.RenderPipeline,
    bind_group: *gpu.BindGroup,
    texture: *gpu.Texture,
    fps: Fps = .{},
    overlay_enabled: bool = false,
    uploaded_fps: ?u16 = null,
    uploaded_revision: ?u64 = null,

    const size = gpu.Extent3D{ .width = video.width, .height = video.height };

    fn init(device: *gpu.Device, format: gpu.Texture.Format) Renderer {
        const texture = device.createTexture(&.{
            .size = size,
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
        });
        const view = texture.createView(&.{});
        defer view.release();
        const bind_layout = device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
            .entries = &.{gpu.BindGroupLayout.Entry.initTexture(
                0,
                .{ .fragment = true },
                .float,
                .dimension_2d,
                false,
            )},
        }));
        defer bind_layout.release();
        const bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .layout = bind_layout,
            .entries = &.{gpu.BindGroup.Entry.initTextureView(0, view)},
        }));
        const layout = device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
            .bind_group_layouts = &.{bind_layout},
        }));
        defer layout.release();
        const shader = device.createShaderModuleWGSL("framebuffer.wgsl", @embedFile("framebuffer.wgsl"));
        defer shader.release();
        const fragment = gpu.FragmentState.init(.{
            .module = shader,
            .entry_point = "fragment_main",
            .targets = &.{.{ .format = format }},
        });
        const pipeline = device.createRenderPipeline(&.{
            .layout = layout,
            .vertex = .{ .module = shader, .entry_point = "vertex_main" },
            .fragment = &fragment,
        });
        return .{ .pipeline = pipeline, .bind_group = bind_group, .texture = texture };
    }

    fn upload(self: *const Renderer, queue: *gpu.Queue, pixels_rgb: *const video.Frame, show_fps: bool) void {
        var pixels: [video.height][video.width][4]u8 = undefined;
        for (&pixels, pixels_rgb) |*target_row, *source_row| {
            for (target_row, source_row) |*target, source| {
                target.* = .{ source.red, source.green, source.blue, 255 };
            }
        }
        if (show_fps) self.fps.draw(&pixels);
        queue.writeTexture(&.{ .texture = self.texture }, &.{
            .bytes_per_row = video.width * 4,
            .rows_per_image = video.height,
        }, &size, std.mem.asBytes(&pixels));
    }
};
