//! Entropia File System Watcher, Zig
//!
//! A light adaptation of the EFSW cross-platform directory watching
//! library.

const root = @This();

/// The raw C bindings to efsw.  Most of these are exposed in `efswz`, but
/// not all: there are some obscure configurable values which may apply
/// to your use case, and a customized watch handle can be created via
/// `c.efsw_addwatch_withoptions`, by assigning the result to the `.raw` field
/// of a newly-created Watcher.  These are various vendor-specific settings
/// where the library has chosen a sensible default: if curious, please
/// consult the header:
///
/// https://github.com/SpartanJ/efsw/blob/master/include/efsw/efsw.h
pub const c = @import("efsw_c");

/// Categories of file and directory action reported by the watcher.
pub const Action = enum(c_int) {
    add = c.EFSW_ADD,
    delete = c.EFSW_DELETE,
    modified = c.EFSW_MODIFIED,
    moved = c.EFSW_MOVED,
};

/// Library-native errors which may arise when registering a watch.
pub const WatchError = error{
    /// Directory doesn't exist, or path is not a directory.
    NotFound,
    /// Directory is already watched by this watcher.
    Repeated,
    /// Directory is a symlink, and symlinks are not enabled, or
    /// if they are, the link is out of pwd scope and out of scope
    /// link follows are not enabled.
    OutOfScope,
    /// The directory can't be read (permissions generally).
    NotReadable,
    /// The directory is on a remote filesystem, and the generic
    /// watcher is not in use.
    Remote,
    /// The watcher tried, and failed, to watch for changes (Win32 specific).
    WatcherFailed,
    /// Something else went wrong, and the library declines to specify it
    /// in any greater detail.
    Unspecified,
};

/// An opaque handle representing a registered watch.  It is more
/// efficient to un-watch by handle than by pathname.  This is
/// also handed to a FileActionCallback, identifying which watch
/// has been activated.
pub const WatchId = enum(c_long) { _ };

/// The Zig-side type signature for a registration callback.
///
/// - `watch_handle`: the C library watcher as `void *`.  This is
///   the same value as the `.raw` field on the `Watcher` which
///   registered the callback.
/// - `watch_id`: the ID returned when this callback was registered
///   to the directory which triggered it.
/// - `dir`: the directory path containing the filesystem event.  If
///   the event is on a directory, this is that directory's parent.
/// - `filename`: the file _or directory_ to which this event pertains.
/// - `action`: the Action reported to have occurred.
/// - `old_filename`: When not "", this is the name of the file prior
///   to the reported Action.
/// - `userdata`:  A pointer to everything you want available within
///   the callback.  Your callback must accept it in type-erased
///   `?*anyopaque` form, but it may be provided to `addWatch` without
///   casting.
///
/// Strings provided to this callback should not be kept, as it is not
/// safe to assume they will live longer than the callback execution.
pub const FileActionCallback = fn (
    watch_handle: c.efsw_watcher,
    watch_id: WatchId,
    dir: []const u8,
    filename: []const u8,
    action: Action,
    old_filename: []const u8,
    userdata: ?*anyopaque,
) void;

/// A single file watcher.  It is possible to have several of these in a single
/// program, with the caveat that `lastError` uses global state.  Includes a
/// 1KiB buffer to transcribe and null-terminate slices.  Since most of `std.fs`
/// deals in `[]const u8`, not its sentinel flavor, and the library does not
/// take a length with its directory names, this was deemed a convenience worth
/// providing.
pub const Watcher = struct {
    raw: c.efsw_watcher,
    buf: [1024]u8 = undefined,

    /// Create a Watcher on the heap and return the pointer.  Free later
    /// with `destroy`.
    pub fn create(allocator: Allocator) OOM!*Watcher {
        const w = try allocator.create(Watcher);
        w.* = .init();
        return w;
    }

    /// Free a heap-allocater Watcher and release its library resources.
    pub fn destroy(watcher: *Watcher, allocator: Allocator) void {
        watcher.deinit();
        allocator.destroy(watcher);
    }

    /// Initialize a Watcher and copy it onto the stack.
    pub fn init() !Watcher {
        const raw = c.efsw_create(@intFromBool(false));
        if (raw == null) return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Initialize a generic watcher, which uses polling to monitor filesystem
    /// events.  This is the fallback strategy of all watchers, and you probably
    /// do not want to use it unconditionally.  I've gleaned one specific virtue
    /// from trawling the library, namely, it can monitor remote filesystems.
    pub fn initGeneric() !Watcher {
        const raw = c.efsw_create(@intFromBool(true));
        if (raw == null) return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Release all library memory held by a stack-allocated Watcher.  A heap
    /// allocated watcher should call `watcher.destroy()` instead.
    pub fn deinit(watcher: *Watcher) void {
        if (watcher.raw != null) {
            c.efsw_release(watcher.raw);
            watcher.raw = null;
        }
    }

    /// Begin watching the filesystem.  This spins out a separate thread.  There
    /// is no way to stop watching other than to deinit the watcher, although
    /// watch targets can be removed while the watcher is running.
    pub fn watch(watcher: Watcher) void {
        c.efsw_watch(watcher.raw);
    }

    /// Obtain a possibly-empty slice, which should have the last error string,
    /// provided this was called after catching a `WatchError`.  This is safe
    /// to use _only_ when there is exactly one Watcher watching, because it
    /// uses a global static variable.  More than one Watcher makes possible a
    /// race condition and memory hazard.  The log string this function provides
    /// contains only a formatted version of state which is already available if
    /// `WatchError` is caught in the scope in which some `addWatch` function is
    /// called.
    pub fn lastError(_: Watcher) []const u8 {
        return root.lastError();
    }

    /// Clear the last error reported by the library.  It is a good idea to
    /// call this after catching a `WatchError`, whether or not `lastError` is
    /// employed, but only if the application uses a single watcher: if there
    /// are several, it is better to eschew both such functions entirely.
    pub fn clearLastError(_: Watcher) void {
        root.clearLastError();
    }

    /// Add a watch on the `directory` path to the watcher.  This may be called
    /// before or after `watcher.watch()`.  Returns a `WatchID` handle, which
    /// can remove this directory from the watchlist in O(1).  The `directory`
    /// slice is limited to 1027 bytes, with an error returned if this is
    /// exceeded.  Prefer `addWatchZ` if a sentinel `0` is already present.  For
    /// the signature needed on the callback, see `FileActionCallback`.  The
    /// watch will be shallow unless `recursive` is made true.  The `userdata`
    /// is an optional pointer which is given to the callback in type-erased
    /// form, but need not be erased prior to the call to `addWatch`.
    ///
    /// All memory passed into this call remains owned by the caller.  Care
    /// should be taken with the `userdata` pointer: it is 'sent' to the watch
    /// thread for the duration of watching, and is not released when the
    /// watcher is: such is the caller's responsibility, sometime after the
    /// watcher is freed.
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

    /// Adds a watch using a null-terminated `directory` slice.  This avoids a
    /// copy, and has no length limit as a result; as such it should be preferred
    /// when a directory path has a sentinel 0.  Remaining details are described
    /// in the documentation of `addWatch`.
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

    /// Adds a directory to the Watcher, with a signature more closely matching
    /// that of the underlying library: null-terminated `directory` argument,
    /// a `callconv(.c)` callback, and a userdata pointer already type-erased by
    /// the caller.
    pub fn addWatchRaw(
        self: *Watcher,
        directory: [:0]const u8,
        callback: c.efsw_pfn_fileaction_callback,
        recursive: bool,
        userdata: ?*anyopaque,
    ) WatchError!WatchId {
        return mapWatchId(c.efsw_addwatch(
            self.raw,
            directory.ptr,
            callback,
            @intFromBool(recursive),
            userdata,
        ));
    }

    /// Remove a directory from the watch list, by giving the `WatchId` returned
    /// from adding it.  Uses binary search in O(logn).
    pub fn removeWatchById(watcher: *const Watcher, watch_id: WatchId) void {
        c.efsw_removewatch_byid(watcher.raw, @backingInt(watch_id));
    }

    /// Remove a directory from the watch list, by path name.  The library
    /// describes this as "a brute force search O(nlogn)".  As with `addWatch`,
    /// this requires a path of 1027 bytes or less, erroring otherwise: if `addWatch`
    /// was used without triggering that error the first time, it will not arise this
    /// time.  A `removeWatchByPathZ` variant is provided.
    pub fn removeWatchByPath(watcher: *Watcher, dir_path: []const u8) error{FilenameTooLong}!void {
        const directory_z = try watcher.copyDirectoryToBuf(dir_path);
        watcher.removeWatchByPathZ(directory_z);
    }

    /// Remove a directory from the watch list, by null-terminated path name.
    /// The library describes this as "a brute force search O(nlogn)", which is
    /// certainly evocative language.
    pub fn removeWatchByPathZ(watcher: *const Watcher, dir_path: [:0]const u8) void {
        c.efsw_removewatch(watcher.raw, dir_path.ptr);
    }

    /// Toggle whether or not the watcher will follow symlinks within its purview.
    /// By default, it will not.  Not all implementations respect this flag.
    pub fn followSymlinks(watcher: *const Watcher, enable: bool) void {
        c.efsw_follow_symlinks(watcher.raw, @intFromBool(enable));
    }

    /// Answer whether the watcher is currently following symlinks it encounters.
    pub fn willFollowSymlinks(watcher: *const Watcher) bool {
        c.efsw_follow_symlinks_isenabled(watcher.raw) == 1;
    }

    /// If `followSymlinks` is enabled, enabling `allowOutOfScopeLinks` will also
    /// oblige the watcher to follow symlinks anywhere they lead, not just within
    /// the nimbus of the watched directory.  This can lead to infinite regress
    /// and crash the program, although some limited and imperfect attempt to
    /// detect cycles is made.  Caveat hacker.
    ///
    /// If `followSymlinks` is not enabled, then this will have no effect beyond
    /// the latent.
    pub fn allowOutOfScopeLinks(watcher: *const Watcher, enable: bool) void {
        c.efsw_allow_outofscopelinks(watcher.raw, @intFromBool(enable));
    }

    /// Answer, somewhat inaccurately, whether the watcher will follow symlinks
    /// which lead out of scope.  The answer `false` is always correct, while
    /// the answer `true` is correct only if `willFollowSymlinks` is also `true`.
    pub fn willAllowOutOfScopeLinks(watcher: *const Watcher) bool {
        c.efsw_outofscopelinks_isallowed(watcher.raw) == 1;
    }

    fn copyDirectoryToBuf(
        watcher: *Watcher,
        directory: []const u8,
    ) error{FilenameTooLong}![:0]const u8 {
        if (directory.len + 1 > watcher.buf.len) return error.FilenameTooLong;
        @memcpy(watcher.buf[0..directory.len], directory);
        watcher.buf[directory.len] = 0;
        return watcher.buf[0..directory.len :0];
    }
};

/// Trivial wrapper over the function which can retrieve an error
/// string.  The string returned is borrowed and will not reliably
/// survive further library interactions, definitely not
/// `clearLastError`.
pub fn lastError() []const u8 {
    const msg = c.efsw_getlasterror();
    return if (msg == null) "" else std.mem.span(msg);
}

/// Clear the last error produced by the library.
pub fn clearLastError() void {
    c.efsw_clearlasterror();
}

/// Adapts a `FileActionCallback` to the form expected by `efzw`.  This is done
/// for you by most callback-taking calls to a `Watcher`, but is left public as
/// an affordance, just in case.
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
                raw_watcher,
                @fromBackingInt(@intCast(raw_watch_id)),
                spanOrEmpty(raw_dir),
                spanOrEmpty(raw_filename),
                @fromBackingInt(@intCast(raw_action)),
                spanOrEmpty(raw_old_filename),
                user_data,
            );
        }
    }.adapted;
}

//| Internal

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
        else => @fromBackingInt(@intCast(raw)),
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
        .null => return null,
        else => @compileError("userdata must be a single-item pointer or optional single-item pointer"),
    }
}

//| Test

const CallbackAdapterTestState = struct {
    called: bool = false,
    watch_handle: ?c.efsw_watcher = null,
    watch_id: ?WatchId = null,
    dir: []const u8 = "",
    filename: []const u8 = "",
    action: ?Action = null,
    old_filename: []const u8 = "",

    fn handle(
        watch_handle: c.efsw_watcher,
        watch_id: WatchId,
        dir: []const u8,
        filename: []const u8,
        action: Action,
        old_filename: []const u8,
        user_data: ?*anyopaque,
    ) void {
        const state: *CallbackAdapterTestState = @ptrCast(@alignCast(user_data.?));
        state.called = true;
        state.watch_handle = watch_handle;
        state.watch_id = watch_id;
        state.dir = dir;
        state.filename = filename;
        state.action = action;
        state.old_filename = old_filename;
    }
};

test "can create and release watcher" {
    var watcher = try Watcher.init();
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
    try std.testing.expectEqual(@as(c.efsw_watcher, @ptrFromInt(0x1234)), state.watch_handle.?);
    try std.testing.expectEqual(@as(WatchId, @fromBackingInt(@intCast(42))), state.watch_id.?);
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

    try std.testing.expect(userdataToOpaquePtr(null) == null);
}

test "addWatch rejects overlong path" {
    var watcher = try Watcher.init();
    defer watcher.deinit();

    const State = struct {
        fn handle(
            _: c.efsw_watcher,
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

test "addWatch and addWatchZ type-check with Zig callback (comptime)" {
    const State = struct {
        fn handle(
            _: c.efsw_watcher,
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const OOM = Allocator.Error;
