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

pub const WatchResult = WatchError!WatchId;

pub fn lastError() []const u8 {
    const msg = c.efsw_getlasterror();
    return if (msg == null) "" else std.mem.span(msg);
}

fn mapWatchId(raw: c.efsw_watchid) WatchResult {
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

pub const Watcher = struct {
    raw: c.efsw_watcher,

    pub fn init(generic_mode: bool) !Watcher {
        const raw = c.efsw_create(@intFromBool(generic_mode));
        if (raw == null) return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Watcher) void {
        if (self.raw != null) {
            c.efsw_release(self.raw);
            self.raw = null;
        }
    }

    pub fn watch(self: Watcher) void {
        c.efsw_watch(self.raw);
    }

    pub fn addWatch(
        self: Watcher,
        directory: [:0]const u8,
        callback: c.efsw_pfn_fileaction_callback,
        recursive: bool,
        user_data: ?*anyopaque,
    ) WatchResult {
        return mapWatchId(c.efsw_addwatch(
            self.raw,
            directory.ptr,
            callback,
            @intFromBool(recursive),
            user_data,
        ));
    }

    pub fn removeWatchById(self: Watcher, watch_id: WatchId) void {
        c.efsw_removewatch_byid(self.raw, @intFromEnum(watch_id));
    }

    pub fn followSymlinks(self: Watcher, enabled: bool) void {
        c.efsw_follow_symlinks(self.raw, @intFromBool(enabled));
    }

    pub fn allowOutOfScopeLinks(self: Watcher, enabled: bool) void {
        c.efsw_allow_outofscopelinks(self.raw, @intFromBool(enabled));
    }
};

test "can create and release watcher" {
    var watcher = try Watcher.init(false);
    defer watcher.deinit();

    try std.testing.expect(watcher.raw != null);
}
