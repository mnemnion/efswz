const std = @import("std");
const efswz = @import("efswz");

fn actionName(action: efswz.Action) []const u8 {
    return switch (action) {
        .add => "add",
        .delete => "delete",
        .modified => "modified",
        .moved => "moved",
    };
}

fn handleFileAction(
    _: efswz.c.efsw_watcher,
    watch_id: efswz.WatchId,
    dir: []const u8,
    filename: []const u8,
    action: efswz.Action,
    old_filename: []const u8,
    _: ?*anyopaque,
) void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    stdout.print(
        "[{d}] {s} dir={s} file={s}",
        .{ @intFromEnum(watch_id), actionName(action), dir, filename },
    ) catch {};

    if (old_filename.len != 0) {
        stdout.print(" old={s}", .{old_filename}) catch {};
    }

    stdout.print("\n", .{}) catch {};
    stdout.flush() catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.err("usage: {s} <path>", .{args[0]});
        return error.InvalidArguments;
    }
    std.debug.print("watching: {s}\n", .{args[1]});

    var watcher = try efswz.Watcher.init();
    defer watcher.deinit();

    const watch_id = watcher.addWatch(
        args[1],
        handleFileAction,
        true,
        @as(?*u8, null),
    ) catch |err| switch (err) {
        error.FilenameTooLong => {
            std.log.err("path is too long for the demo watcher buffer: {s}", .{args[1]});
            return err;
        },
        else => {
            std.log.err("failed to watch {s}: {s}", .{ args[1], watcher.lastError() });
            return err;
        },
    };

    watcher.watch();

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "watching {s} recursively (watch id {d})\npress ^C to quit\n",
        .{ args[1], @intFromEnum(watch_id) },
    );
    try stdout.flush();

    while (true) {
        std.Thread.sleep(std.time.ns_per_s);
    }
}
