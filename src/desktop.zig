const std = @import("std");
const mach = @import("mach");
const objc = @import("objc");
const gpu = mach.gpu;
const snapshot = @import("main.zig");
const video = @import("video.zig");
const Playback = @import("desktop_audio.zig");
const Machine = @import("machine.zig");
const input = @import("input.zig");
const timing = @import("timing.zig");
const save_file = @import("save_file.zig");

const frame_period_ns = timing.cycles_per_frame * std.time.ns_per_s / (1 << 24);
const window_scale = 3;
const window_width = video.width * window_scale;
const window_height = video.height * window_scale;
const black: video.Rgb = .{ .red = 0, .green = 0, .blue = 0 };

const Modules = mach.Modules(.{ mach.Core, App });

// The launcher sets these before Mach starts its threads. Live frames are
// published under Mach's snapshot lock (also held by the render callback).
var frame: video.Frame = @splat(@splat(black));
var live_machine: ?*Machine = null;
var live_audio: ?*Playback = null;
var live_error: ?anyerror = null;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = (try init.minimal.args.toSlice(arena))[1..];
    var save_options: save_file.Options = .{};
    var volume: u8 = 30;
    while (args.len != 0) {
        if (try save_options.take(&args)) continue;
        if (std.mem.eql(u8, args[0], "--mute")) {
            volume = 0;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "--volume") and args.len >= 2) {
            volume = try std.fmt.parseInt(u8, args[1], 10);
            if (volume > 100) return error.InvalidVolume;
            args = args[2..];
        } else break;
    }
    if (args.len != 2) {
        std.debug.print(
            "Usage: zaza-window <input.gba> <steps>\n" ++
                "       zaza-window [--mute | --volume 0..100] --live <input.gba>\n" ++
                "       Cartridge options: --save <path>, --save-type <type>\n",
            .{},
        );
        return error.InvalidArguments;
    }
    const live = std.mem.eql(u8, args[0], "--live");
    const rom = try snapshot.loadRom(init.io, arena, if (live) args[1] else args[0]);
    const machine = try arena.create(Machine);
    machine.initCartridgeWithBios(rom, snapshot.bundled_bios);
    var save = try save_options.open(init.io, arena, &machine.bus.save);
    defer if (save) |session| session.close(init.io);
    var playback: Playback = undefined;
    defer if (live_audio) |audio| audio.deinit();
    if (live) {
        if (volume != 0) {
            if (playback.init(init.gpa, volume)) {
                live_audio = &playback;
                machine.bus.audio.capture = &playback.capture;
            } else |err| std.log.warn("audio output unavailable ({s}), continuing muted", .{@errorName(err)});
        }
        live_machine = machine;
    } else {
        const steps = try std.fmt.parseInt(usize, args[1], 10);
        if (steps == 0) return error.InvalidStepCount;
        try snapshot.captureMachineBitmap(machine, steps, &frame);
    }

    var modules: Modules = undefined;
    try modules.init(init.gpa, init.io);
    defer modules.deinit(init.gpa);
    modules.get(.app).run(.main);
    if (live_error) |err| return err;
    if (save) |*session| try session.flush(init.io, &machine.bus.save);
}

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

    app_thread: mach.Thread,
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
        core.on_exit = app_mod.id.deinit;
        const window_id = try core.windows.new(.{
            .title = "Zaza",
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
        lockWindowSize(window);
        app.* = .{ .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app) };
    }

    pub fn pollInput(app: *App, core: *mach.Core) void {
        var events = core.events(.default);
        while (events.next()) |event| {
            switch (event) {
                .close => core.exit(),
                .focus_lost => app.keys = .{},
                .key_press => |key| if (key.key == .escape) {
                    core.exit();
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
        const machine = live_machine orelse return;
        if (live_error != null or core.state.load(.acquire) != .running) return;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        const deadline_ns = app.next_frame_ns orelse now_ns;
        if (now_ns < deadline_ns) return;
        // Keep the cadence despite polling jitter, but avoid an unbounded backlog.
        app.next_frame_ns = @max(now_ns, deadline_ns + frame_period_ns);
        machine.runFrame(app.keys.sample()) catch |err| {
            std.log.err("live emulation stopped at 0x{x:0>8}", .{machine.cpu.instruction_address});
            live_error = err;
            core.exit();
            return;
        };
        if (live_audio) |audio| {
            if (audio.capture.failure) |err| {
                live_error = err;
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
        if (app.pending) |next_frame| {
            frame = next_frame;
            app.pending = null;
            app.frame_revision +%= 1;
        }
    }

    pub fn render(app: *App, core: *mach.Core) void {
        const window = core.windows.getValue(core.window);
        if (app.renderer == null) {
            app.renderer = Renderer.init(window.device, window.framebuffer_format);
        }
        const renderer = &app.renderer.?;
        if (renderer.uploaded_revision != app.frame_revision) {
            renderer.upload(window.queue, &frame);
            renderer.uploaded_revision = app.frame_revision;
        }
        const target = window.swap_chain.getCurrentTextureView() orelse return;
        defer target.release();
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

    pub fn deinit(app: *App) void {
        app.app_thread.join();
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

    fn upload(self: *const Renderer, queue: *gpu.Queue, pixels_rgb: *const video.Frame) void {
        var pixels: [video.height][video.width][4]u8 = undefined;
        for (&pixels, pixels_rgb) |*target_row, *source_row| {
            for (target_row, source_row) |*target, source| {
                target.* = .{ source.red, source.green, source.blue, 255 };
            }
        }
        queue.writeTexture(&.{ .texture = self.texture }, &.{
            .bytes_per_row = video.width * 4,
            .rows_per_image = video.height,
        }, &size, std.mem.asBytes(&pixels));
    }
};
