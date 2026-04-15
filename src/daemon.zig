const std = @import("std");
const x11 = @import("x11.zig");
const db = @import("db.zig");
const posix = @cImport({
    @cInclude("signal.h");
});

var should_quit = std.atomic.Value(bool).init(false);

fn signalHandler(_: c_int) callconv(.c) void {
    should_quit.store(true, .release);
}

/// Main daemon loop. Only allocates on startup (DB path).
pub fn run(allocator: std.mem.Allocator, poll_interval: u32, afk_timeout: u32) !void {
    _ = posix.signal(posix.SIGINT, signalHandler);
    _ = posix.signal(posix.SIGTERM, signalHandler);

    var display = try x11.X11.init();
    defer display.deinit();

    var database = try db.Db.open(allocator);
    defer database.close();

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.print("ebyt daemon started (poll={d}s, afk={d}s)\n", .{ poll_interval, afk_timeout });
    try stdout.interface.flush();

    var last_input_time = std.time.timestamp();
    var current_id: ?i64 = null;
    var current_class: [256]u8 = [_]u8{0} ** 256;
    var current_class_len: usize = 0;
    var current_afk = false;

    while (!should_quit.load(.acquire)) {
        // X11 events (key, mouse, button) accumulate in the socket buffer
        // during sleep. Drain them all now to update last-input time.
        if (display.drainEvents()) {
            last_input_time = std.time.timestamp();
        }

        const now = std.time.timestamp();
        const idle_seconds = now - last_input_time;
        const is_afk = idle_seconds > @as(i64, afk_timeout);

        const win_info = display.getActiveWindow();
        const class = if (win_info) |w| w.class else "unknown";
        const title = if (win_info) |w| w.title else "";

        // Decide: extend current row or insert new one
        const afk_changed = is_afk != current_afk;
        const class_changed = !is_afk and
            ((class.len != current_class_len) or
                !std.mem.eql(u8, class, current_class[0..current_class_len]));

        if (current_id != null and !afk_changed and !class_changed) {
            database.extendActivity(current_id.?, now) catch |err| {
                std.log.warn("db extend failed, skipping cycle: {}", .{err});
                continue;
            };
        } else {
            const new_id = database.insertActivity(
                if (is_afk) "AFK" else class,
                if (is_afk) "" else title,
                now,
                is_afk,
            ) catch |err| {
                std.log.warn("db insert failed, skipping cycle: {}", .{err});
                continue;
            };
            current_id = new_id;

            const copy_len = @min(class.len, current_class.len);
            @memcpy(current_class[0..copy_len], class[0..copy_len]);
            current_class_len = copy_len;
            current_afk = is_afk;
        }

        std.Thread.sleep(@as(u64, poll_interval) * std.time.ns_per_s);
    }

    try stdout.interface.writeAll("ebyt daemon stopped\n");
    try stdout.interface.flush();
}
