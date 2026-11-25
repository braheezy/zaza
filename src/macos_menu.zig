//! AppKit owns menu tracking, key equivalents and the file chooser on the main thread.
const std = @import("std");
const objc = @import("objc");
const ns = objc.foundation;
const Id = objc.objc.Id;
const Class = objc.objc.Class;
const Selector = *opaque {};
const send = objc.objc.msgSend;
const string = ns.String.stringWithUTF8String;

pub const Action = enum(isize) { open_rom, toggle_pause, quit };

extern "objc" fn sel_registerName(name: [*:0]const u8) Selector;
extern "objc" fn objc_allocateClassPair(super: *Class, name: [*:0]const u8, extra: usize) ?*Class;
extern "objc" fn objc_registerClassPair(cls: *Class) void;
extern "objc" fn object_getClass(cls: *Class) *Class;
extern "objc" fn class_addMethod(cls: *Class, sel: Selector, imp: *const anyopaque, types: [*:0]const u8) bool;
extern "objc" fn imp_implementationWithBlock(block: *const anyopaque) *const anyopaque;

fn class(comptime name: []const u8) *Class {
    return objc.objc.ExternClass(name, Id, ns.ObjectInterface, &.{}).class();
}

pause_item: *Id,

pub fn install(context: anytype, comptime perform: fn (@TypeOf(context), Action) void) !@This() {
    // Register one target for the application's lifetime. Each item's tag selects its action.
    const Target = struct {
        fn invoke(block: *ns.BlockLiteral(@TypeOf(context)), _: *Class, item: *Id) callconv(.c) void {
            perform(block.context, @enumFromInt(send(item, "tag", isize, .{})));
        }
    };
    const target = objc_allocateClassPair(ns.ObjectInterface.InternalInfo.class(), "ZazaMenuCommands", 0) orelse
        return error.MenuTargetUnavailable;
    const action = sel_registerName("performZazaCommand:");
    var block = ns.stackBlockLiteral(Target.invoke, context, null, null);
    const imp = imp_implementationWithBlock(block.asBlock());
    if (!class_addMethod(object_getClass(target), action, imp, "v@:@")) return error.MenuActionUnavailable;
    objc_registerClassPair(target);

    const bar = send(class("NSMenu"), "new", *Id, .{});
    defer bar.release();
    const application_menu = addSubmenu(bar, "Zaza");
    _ = addCommand(application_menu, target, action, .quit, "Quit Zaza", "q");
    const file_menu = addSubmenu(bar, "File");
    _ = addCommand(file_menu, target, action, .open_rom, "Open ROM…", "o");
    const emulation = addSubmenu(bar, "Emulation");
    send(emulation, "setAutoenablesItems:", void, .{false});
    const pause_item = addCommand(emulation, target, action, .toggle_pause, "Pause", "p");
    send(objc.app_kit.Application.sharedApplication(), "setMainMenu:", void, .{bar});
    return .{ .pause_item = pause_item };
}

pub fn updatePause(menu: @This(), loaded: bool, paused: bool) void {
    send(menu.pause_item, "setEnabled:", void, .{loaded});
    send(menu.pause_item, "setTitle:", void, .{string(if (paused) "Resume" else "Pause")});
}

fn addSubmenu(bar: *Id, title: [:0]const u8) *Id {
    const item = send(class("NSMenuItem"), "new", *Id, .{});
    defer item.release();
    send(bar, "addItem:", void, .{item});
    const menu = send(send(class("NSMenu"), "alloc", *Id, .{}), "initWithTitle:", *Id, .{string(title)});
    defer menu.release();
    send(item, "setSubmenu:", void, .{menu});
    return menu;
}

fn addCommand(menu: *Id, target: *Class, selector: Selector, action: Action, title: [:0]const u8, key: [:0]const u8) *Id {
    const item = send(menu, "addItemWithTitle:action:keyEquivalent:", *Id, .{
        string(title), selector, string(key),
    });
    send(item, "setTarget:", void, .{target});
    send(item, "setTag:", void, .{@intFromEnum(action)});
    return item;
}

/// The selected URL is autoreleased. Consume its filesystem path in the menu callback.
pub fn chooseRom() ?[]const u8 {
    const panel = send(class("NSOpenPanel"), "openPanel", *Id, .{});
    send(panel, "setTitle:", void, .{string("Open ROM")});
    const gba = send(class("UTType"), "typeWithFilenameExtension:", *Id, .{string("gba")});
    send(panel, "setAllowedContentTypes:", void, .{send(class("NSArray"), "arrayWithObject:", *Id, .{gba})});
    if (send(panel, "runModal", isize, .{}) != 1) return null;
    const url = send(panel, "URL", *ns.URL, .{});
    return std.mem.span(url.fileSystemRepresentation());
}

pub fn showOpenError(path: []const u8, err: anyerror) void {
    const alert = send(class("NSAlert"), "new", *Id, .{});
    defer alert.release();
    send(alert, "setMessageText:", void, .{string("Couldn’t open the ROM")});
    var buffer: [1024]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&buffer, "{s}\n{s}", .{
        std.Io.Dir.path.basename(path), @errorName(err),
    }) catch @errorName(err);
    send(alert, "setInformativeText:", void, .{string(detail)});
    _ = send(alert, "runModal", isize, .{});
}
