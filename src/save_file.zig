const std = @import("std");
const SaveMemory = @import("libzaza").SaveMemory;

pub const Options = struct {
    path: ?[]const u8 = null,
    kind: ?SaveMemory.Kind = null,

    pub fn take(self: *Options, args: *[]const [:0]const u8) !bool {
        if (args.len == 0) return false;
        const option = args.*[0];
        if (std.mem.eql(u8, option, "--save")) {
            if (args.len < 2 or self.path != null) return error.InvalidSaveOption;
            self.path = args.*[1];
        } else if (std.mem.eql(u8, option, "--save-type")) {
            if (args.len < 2 or self.kind != null) return error.InvalidSaveOption;
            self.kind = std.meta.stringToEnum(SaveMemory.Kind, args.*[1]) orelse
                return error.InvalidSaveType;
        } else return false;
        args.* = args.*[2..];
        return true;
    }

    pub fn open(
        self: Options,
        io: std.Io,
        allocator: std.mem.Allocator,
        save: *SaveMemory,
    ) !?Session {
        const path = try self.prepare(save) orelse return null;

        const directory = std.Io.Dir.cwd();
        // Lock a stable inode since publishing a save replaces the data file's inode.
        const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
        defer allocator.free(lock_path);
        const lock = try directory.createFile(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer lock.close(io);

        const exists = try readInitial(io, allocator, save, path);
        return .{ .path = path, .lock = lock, .exists = exists };
    }

    /// Load the starting contents without opening a session that can write them back.
    pub fn loadInitial(
        self: Options,
        io: std.Io,
        allocator: std.mem.Allocator,
        save: *SaveMemory,
    ) !void {
        const path = try self.prepare(save) orelse return;
        const exists = try readInitial(io, allocator, save, path);
        if (!exists) return error.FileNotFound;
    }

    fn prepare(self: Options, save: *SaveMemory) !?[]const u8 {
        if (self.kind) |kind| save.kind = kind;
        const path = self.path orelse return null;
        if (save.kind == .none) return error.NoSaveMemory;
        if (path.len == 0) return error.InvalidSaveOption;
        return path;
    }

    fn readInitial(
        io: std.Io,
        allocator: std.mem.Allocator,
        save: *SaveMemory,
        path: []const u8,
    ) !bool {
        const data = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(SaveMemory.Kind.flash128.size()),
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.StreamTooLong => return error.InvalidSaveSize,
            else => |failure| return failure,
        };
        defer allocator.free(data);
        try save.load(data);
        return true;
    }
};

pub const Session = struct {
    path: []const u8,
    lock: std.Io.File,
    exists: bool,

    pub fn close(self: Session, io: std.Io) void {
        self.lock.close(io);
    }

    pub fn flush(self: *Session, io: std.Io, save: *SaveMemory) !void {
        if (!save.dirty) return;
        var file = try std.Io.Dir.cwd().createFileAtomic(io, self.path, .{
            .replace = self.exists,
        });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, save.bytes());
        try file.file.sync(io);
        if (self.exists) try file.replace(io) else try file.link(io);
        self.exists = true;
        save.dirty = false;
    }
};
