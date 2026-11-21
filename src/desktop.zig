const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const snapshot = @import("main.zig");
const video = @import("video.zig");

const Modules = mach.Modules(.{ mach.Core, App });

// Captured before Mach starts either of its threads.
var frame: video.Frame = undefined;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("Usage: zaza-window <input.gba> <steps>\n", .{});
        return error.InvalidArguments;
    }
    const steps = try std.fmt.parseInt(usize, args[2], 10);
    if (steps == 0) return error.InvalidStepCount;
    const rom = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.arena.allocator(),
        .limited(32 * 1024 * 1024),
    );
    if (rom.len < 8) return error.RomTooShort;
    try snapshot.captureMode3(rom, snapshot.bundled_bios, steps, &frame);

    var modules: Modules = undefined;
    try modules.init(init.gpa, init.io);
    defer modules.deinit(init.gpa);
    modules.get(.app).run(.main);
}

const App = struct {
    pub const mach_module = .app;
    pub const mach_systems = .{ .main, .init, .tick, .input, .render, .deinit };
    pub const main = mach.schedule(.{
        .{ mach.Core, .init },
        .{ App, .init },
        .{ mach.Core, .main },
    });
    pub const tick = mach.schedule(.{
        .{ App, .input },
        .{ mach.Core, .snapshotStart },
        .{ mach.Core, .snapshotEnd },
    });

    app_thread: mach.Thread,
    renderer: ?Renderer = null,

    pub fn init(app: *App, core: *mach.Core, app_mod: mach.Mod(App), core_mod: mach.Mod(mach.Core)) !void {
        core.on_exit = app_mod.id.deinit;
        _ = try core.windows.new(.{
            .title = "Zaza",
            .width = video.width * 3,
            .height = video.height * 3,
            .on_render = app_mod.id.render,
        });
        app.* = .{ .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app) };
    }

    pub fn input(core: *mach.Core) void {
        var events = core.events(.default);
        while (events.next()) |event| {
            switch (event) {
                .close => core.exit(),
                else => {},
            }
        }
    }

    pub fn render(app: *App, core: *mach.Core) void {
        const window = core.windows.getValue(core.window);
        if (app.renderer == null) {
            app.renderer = Renderer.init(window.device, window.queue, window.framebuffer_format);
        }
        const renderer = app.renderer.?;
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
        }
    }
};

const Renderer = struct {
    pipeline: *gpu.RenderPipeline,
    bind_group: *gpu.BindGroup,

    fn init(device: *gpu.Device, queue: *gpu.Queue, format: gpu.Texture.Format) Renderer {
        const size = gpu.Extent3D{ .width = video.width, .height = video.height };
        const texture = device.createTexture(&.{
            .size = size,
            .format = .rgba8_unorm,
            .usage = .{ .copy_dst = true, .texture_binding = true },
        });
        defer texture.release();
        var pixels: [video.height][video.width][4]u8 = undefined;
        for (&pixels, &frame) |*target_row, *source_row| {
            for (target_row, source_row) |*target, source| {
                target.* = .{ source.red, source.green, source.blue, 255 };
            }
        }
        queue.writeTexture(&.{ .texture = texture }, &.{
            .bytes_per_row = video.width * 4,
            .rows_per_image = video.height,
        }, &size, std.mem.asBytes(&pixels));

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
        return .{ .pipeline = pipeline, .bind_group = bind_group };
    }
};
