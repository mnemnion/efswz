const std = @import("std");

pub const c = @cImport({
    @cInclude("efsw/efsw.h");
});

pub const Action = enum(c_int) {
    add = c.EFSW_ADD,
    delete = c.EFSW_DELETE,
    modified = c.EFSW_MODIFIED,
    moved = c.EFSW_MOVED,
};

pub const WatchError = error{
    NotFound,
    Repeated,
    OutOfScope,
    NotReadable,
    Remote,
    WatcherFailed,
    Unspecified,
};

pub const WatchId = enum(c_long) {
    _,
};

pub const FileActionCallback = fn (
    watcher: Watcher,
    watch_id: WatchId,
    dir: []const u8,
    filename: []const u8,
    action: Action,
    old_filename: []const u8,
    user_data: ?*anyopaque,
) void;

pub fn lastEfswError() []const u8 {
    const msg = c.efsw_getlasterror();
    return if (msg == null) "" else std.mem.span(msg);
}

fn spanOrEmpty(ptr: ?[*:0]const u8) []const u8 {
    return if (ptr) |str| std.mem.span(str) else "";
}

fn mapWatchId(raw: c.efsw_watchid) WatchError!WatchId {
    return switch (raw) {
        c.EFSW_NOTFOUND => WatchError.NotFound,
        c.EFSW_REPEATED => WatchError.Repeated,
        c.EFSW_OUTOFSCOPE => WatchError.OutOfScope,
        c.EFSW_NOTREADABLE => WatchError.NotReadable,
        c.EFSW_REMOTE => WatchError.Remote,
        c.EFSW_WATCHER_FAILED => WatchError.WatcherFailed,
        c.EFSW_UNSPECIFIED => WatchError.Unspecified,
        else => @enumFromInt(raw),
    };
}

fn userdataToOpaquePtr(userdata: anytype) ?*anyopaque {
    const T = @TypeOf(userdata);
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |pointer| {
            if (pointer.size != .one) {
                @compileError("userdata must be a single-item pointer or optional single-item pointer");
            }
            return @ptrCast(userdata);
        },
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| {
                if (pointer.size != .one) {
                    @compileError("userdata must be a single-item pointer or optional single-item pointer");
                }
                return if (userdata) |ptr| @ptrCast(ptr) else null;
            },
            else => @compileError("userdata must be a single-item pointer or optional single-item pointer"),
        },
        else => @compileError("userdata must be a single-item pointer or optional single-item pointer"),
    }
}

pub fn callbackAdapter(comptime callback: FileActionCallback) c.efsw_pfn_fileaction_callback {
    return struct {
        fn adapted(
            raw_watcher: c.efsw_watcher,
            raw_watch_id: c.efsw_watchid,
            raw_dir: [*c]const u8,
            raw_filename: [*c]const u8,
            raw_action: c.enum_efsw_action,
            raw_old_filename: [*c]const u8,
            user_data: ?*anyopaque,
        ) callconv(.c) void {
            callback(
                .{ .raw = raw_watcher },
                @enumFromInt(raw_watch_id),
                spanOrEmpty(raw_dir),
                spanOrEmpty(raw_filename),
                @enumFromInt(raw_action),
                spanOrEmpty(raw_old_filename),
                user_data,
            );
        }
    }.adapted;
}

pub const Watcher = struct {
    raw: c.efsw_watcher,
    buf: [1024]u8 = undefined,

    pub fn init(generic_mode: bool) !Watcher {
        const raw = c.efsw_create(@intFromBool(generic_mode));
        if (raw == null) return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn deinit(watcher: *Watcher) void {
        if (watcher.raw != null) {
            c.efsw_release(watcher.raw);
            watcher.raw = null;
        }
    }

    pub fn watch(watcher: Watcher) void {
        c.efsw_watch(watcher.raw);
    }

    pub fn lastError(_: Watcher) []const u8 {
        return lastEfswError();
    }

    pub fn addWatchRaw(
        self: Watcher,
        directory: [:0]const u8,
        callback: c.efsw_pfn_fileaction_callback,
        recursive: bool,
        user_data: ?*anyopaque,
    ) WatchError!WatchId {
        return mapWatchId(c.efsw_addwatch(
            self.raw,
            directory.ptr,
            callback,
            @intFromBool(recursive),
            user_data,
        ));
    }

    pub fn addWatch(
        watcher: *Watcher,
        directory: []const u8,
        comptime callback: FileActionCallback,
        recursive: bool,
        userdata: anytype,
    ) (WatchError || error{FilenameTooLong})!WatchId {
        const directory_z = try watcher.copyDirectoryToBuf(directory);
        return watcher.addWatchRaw(
            directory_z,
            callbackAdapter(callback),
            recursive,
            userdataToOpaquePtr(userdata),
        );
    }

    pub fn addWatchZ(
        watcher: *Watcher,
        directory: [:0]const u8,
        comptime callback: FileActionCallback,
        recursive: bool,
        userdata: anytype,
    ) WatchError!WatchId {
        return watcher.addWatchRaw(
            directory,
            callbackAdapter(callback),
            recursive,
            userdataToOpaquePtr(userdata),
        );
    }

    pub fn removeWatchById(watcher: Watcher, watch_id: WatchId) void {
        c.efsw_removewatch_byid(watcher.raw, @intFromEnum(watch_id));
    }

    pub fn followSymlinks(watcher: Watcher, enabled: bool) void {
        c.efsw_follow_symlinks(watcher.raw, @intFromBool(enabled));
    }

    pub fn allowOutOfScopeLinks(watcher: Watcher, enabled: bool) void {
        c.efsw_allow_outofscopelinks(watcher.raw, @intFromBool(enabled));
    }

    fn copyDirectoryToBuf(watcher: *Watcher, directory: []const u8) error{FilenameTooLong}![:0]const u8 {
        if (directory.len + 1 > watcher.buf.len) return error.FilenameTooLong;
        @memcpy(watcher.buf[0..directory.len], directory);
        watcher.buf[directory.len] = 0;
        return watcher.buf[0..directory.len :0];
    }
};

//| Test

const CallbackAdapterTestState = struct {
    called: bool = false,
    watcher: ?c.efsw_watcher = null,
    watch_id: ?WatchId = null,
    dir: []const u8 = "",
    filename: []const u8 = "",
    action: ?Action = null,
    old_filename: []const u8 = "",

    fn handle(
        watcher: Watcher,
        watch_id: WatchId,
        dir: []const u8,
        filename: []const u8,
        action: Action,
        old_filename: []const u8,
        user_data: ?*anyopaque,
    ) void {
        const state: *CallbackAdapterTestState = @ptrCast(@alignCast(user_data.?));
        state.called = true;
        state.watcher = watcher.raw;
        state.watch_id = watch_id;
        state.dir = dir;
        state.filename = filename;
        state.action = action;
        state.old_filename = old_filename;
    }
};

test "can create and release watcher" {
    var watcher = try Watcher.init(false);
    defer watcher.deinit();

    try std.testing.expect(watcher.raw != null);
}

test "callbackAdapter converts callback arguments" {
    var state = CallbackAdapterTestState{};
    const callback = callbackAdapter(CallbackAdapterTestState.handle);

    callback.?(
        @ptrFromInt(0x1234),
        42,
        "root/path",
        "hello.txt",
        c.EFSW_MOVED,
        "before.txt",
        &state,
    );

    try std.testing.expect(state.called);
    try std.testing.expectEqual(@as(c.efsw_watcher, @ptrFromInt(0x1234)), state.watcher.?);
    try std.testing.expectEqual(@as(WatchId, @enumFromInt(42)), state.watch_id.?);
    try std.testing.expectEqualStrings("root/path", state.dir);
    try std.testing.expectEqualStrings("hello.txt", state.filename);
    try std.testing.expectEqual(Action.moved, state.action.?);
    try std.testing.expectEqualStrings("before.txt", state.old_filename);
}

test "userdataToOpaquePtr accepts pointer and optional pointer" {
    var value: u32 = 7;
    const ptr = userdataToOpaquePtr(&value);
    try std.testing.expect(ptr != null);

    const maybe_ptr: ?*u32 = &value;
    const maybe = userdataToOpaquePtr(maybe_ptr);
    try std.testing.expect(maybe != null);

    const none: ?*u32 = null;
    try std.testing.expect(userdataToOpaquePtr(none) == null);
}

test "addWatch rejects overlong path" {
    var watcher = try Watcher.init(false);
    defer watcher.deinit();

    const State = struct {
        fn handle(
            _: Watcher,
            _: WatchId,
            _: []const u8,
            _: []const u8,
            _: Action,
            _: []const u8,
            _: ?*anyopaque,
        ) void {}
    };

    var too_long: [1024]u8 = undefined;
    @memset(&too_long, 'a');

    try std.testing.expectError(
        error.FilenameTooLong,
        watcher.addWatch(too_long[0..], State.handle, true, @as(?*u8, null)),
    );
}

test "addWatch and addWatchZ type-check with Zig callback" {
    const State = struct {
        fn handle(
            _: Watcher,
            _: WatchId,
            _: []const u8,
            _: []const u8,
            _: Action,
            _: []const u8,
            _: ?*anyopaque,
        ) void {}
    };

    const RawUse = struct {
        fn compileOnly() void {
            const c_callback: c.efsw_pfn_fileaction_callback = callbackAdapter(State.handle);
            const userdata = userdataToOpaquePtr(@as(?*u8, null));
            _ = c_callback;
            _ = userdata;
        }
    };

    RawUse.compileOnly();
}
