const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const db = @import("db.zig");

pub const ExportMode = union(enum) {
    today,
    week,
    since: []const u8,
};

pub fn exportCsv(allocator: std.mem.Allocator, mode: ExportMode) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var database = try db.Db.open(alloc);
    defer database.close();

    const now = std.time.timestamp();
    const range = getTimeRange(now, mode);
    const rows = try database.queryCsv(alloc, range[0], range[1]);

    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const w = &out.interface;

    try w.writeAll("window_class,window_title,start_time,duration(s)\n");
    for (rows) |row| {
        const class = row.window_class[0..row.class_len];
        const title = row.window_title[0..row.title_len];
        try writeCsvField(w, class);
        try w.writeAll(",");
        try writeCsvField(w, title);
        try w.print(",{d},{d}\n", .{ row.start_time, row.duration });
    }
    try w.flush();
}

pub fn status(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var database = try db.Db.open(alloc);
    defer database.close();

    var buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const w = &out.interface;
    const tty = std.posix.isatty(std.fs.File.stdout().handle);

    const latest = try database.getLatestActivity();
    if (latest) |act| {
        const now = std.time.timestamp();
        const age = now - act.end_time;

        if (age > 30) {
            if (tty) try w.writeAll("\x1b[2m");
            try w.writeAll("Daemon is not running (no recent activity)\n");
            if (tty) try w.writeAll("\x1b[0m");
        } else {
            if (tty) try w.writeAll("\x1b[1m");
            try w.print("Tracking: {s}", .{act.windowClass()});
            if (tty) try w.writeAll("\x1b[0m");
            if (act.windowTitle().len > 0) {
                if (tty) try w.writeAll("\x1b[2m");
                try w.print(" — {s}", .{act.windowTitle()});
                if (tty) try w.writeAll("\x1b[0m");
            }
            try w.writeAll("\n");
            try w.writeAll("Duration: ");
            if (tty) try w.writeAll("\x1b[1m");
            const secs: u64 = @intCast(@max(act.end_time - act.start_time, 0));
            try w.print("{d}h {d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 });
            if (tty) try w.writeAll("\x1b[0m");
            try w.writeAll("\n");
        }
    } else {
        try w.writeAll("No activity recorded yet.\n");
    }
    try w.flush();
}

fn writeCsvField(writer: anytype, field: []const u8) !void {
    var needs_quote = false;
    for (field) |ch| {
        if (ch == ',' or ch == '"' or ch == '\n') {
            needs_quote = true;
            break;
        }
    }
    if (needs_quote) {
        try writer.writeAll("\"");
        for (field) |ch| {
            if (ch == '"') {
                try writer.writeAll("\"\"");
            } else {
                try writer.writeByte(ch);
            }
        }
        try writer.writeAll("\"");
    } else {
        try writer.writeAll(field);
    }
}

fn getTimeRange(now: i64, mode: ExportMode) [2]i64 {
    return switch (mode) {
        .today => .{ startOfDay(now), now },
        .week => .{ startOfWeek(now), now },
        .since => |date_str| .{ parseDate(date_str) catch startOfDay(now), now },
    };
}

fn startOfDay(timestamp: i64) i64 {
    var t: c.time_t = @intCast(timestamp);
    const tm = c.localtime(&t) orelse return timestamp - @mod(timestamp, 86400);
    return timestamp - @as(i64, tm.*.tm_hour) * 3600 - @as(i64, tm.*.tm_min) * 60 - @as(i64, tm.*.tm_sec);
}

fn startOfWeek(timestamp: i64) i64 {
    const day_start = startOfDay(timestamp);
    var t: c.time_t = @intCast(day_start);
    const tm = c.localtime(&t) orelse return day_start;
    const days_since_monday: i64 = if (tm.*.tm_wday == 0) 6 else @as(i64, tm.*.tm_wday) - 1;
    return day_start - (days_since_monday * 86400);
}

fn parseDate(date_str: []const u8) !i64 {
    if (date_str.len != 10) return error.InvalidDate;
    if (date_str[4] != '-' or date_str[7] != '-') return error.InvalidDate;

    const year = std.fmt.parseInt(c_int, date_str[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(c_int, date_str[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(c_int, date_str[8..10], 10) catch return error.InvalidDate;

    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

    var tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_isdst = -1;

    const result = c.mktime(&tm);
    if (result == -1) return error.InvalidDate;
    return @intCast(result);
}

// -- tests --

test "writeCsvField plain" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeCsvField(fbs.writer(), "hello");
    try std.testing.expectEqualStrings("hello", fbs.getWritten());
}

test "writeCsvField with comma" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeCsvField(fbs.writer(), "a,b");
    try std.testing.expectEqualStrings("\"a,b\"", fbs.getWritten());
}

test "writeCsvField with quotes" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeCsvField(fbs.writer(), "say \"hi\"");
    try std.testing.expectEqualStrings("\"say \"\"hi\"\"\"", fbs.getWritten());
}

test "parseDate valid" {
    const ts = try parseDate("2026-01-01");
    try std.testing.expect(ts > 0);
}

test "parseDate rejects bad format" {
    try std.testing.expectError(error.InvalidDate, parseDate("2026/01/01"));
    try std.testing.expectError(error.InvalidDate, parseDate("not-a-date"));
    try std.testing.expectError(error.InvalidDate, parseDate("2026-13-01"));
    try std.testing.expectError(error.InvalidDate, parseDate("2026-00-01"));
}
