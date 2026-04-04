const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const db = @import("db.zig");

pub const ReportMode = union(enum) {
    today,
    week,
    since: []const u8,
};

pub const OutputFormat = enum {
    summary,
    detail,
    csv,
};

pub fn show(allocator: std.mem.Allocator, mode: ReportMode, format: OutputFormat) !void {
    if (format == .csv) return showCsv(allocator, mode);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var database = db.Db.open(alloc) catch |err| {
        try std.io.getStdErr().writer().print("Failed to open database: {}\n", .{err});
        std.process.exit(1);
    };
    defer database.close();

    const now = std.time.timestamp();
    const range = getTimeRange(now, mode);
    const from = range[0];
    const to = range[1];

    const rows = try database.queryReport(alloc, from, to);
    const afk_seconds = try database.queryAfkTime(from, to);
    const detail_rows = if (format == .detail) try database.queryDetail(alloc, from, to) else &[_]db.DetailRow{};

    const writer = std.io.getStdOut().writer();
    const tty = isatty();

    // Header
    const label = formatRangeLabel(alloc, from, to, mode);
    try writer.writeAll("\n");
    try writeAnsi(writer, ansi.bold, tty);
    try writer.print("Activity Report — {s}\n", .{label});
    try writeAnsi(writer, ansi.reset, tty);
    try writeAnsi(writer, ansi.dim, tty);
    try writer.writeAll("─────────────────────────────────────────────────────────────────\n");
    try writeAnsi(writer, ansi.reset, tty);

    // Totals
    var total_active: i64 = 0;
    for (rows) |row| {
        total_active += row.total_seconds;
    }
    const total_tracked = total_active + afk_seconds;

    if (total_tracked == 0) {
        try writer.writeAll("  No activity recorded.\n\n");
        return;
    }

    // Body
    for (rows) |row| {
        const name = row.window_class[0..row.class_len];
        try printAppRow(writer, name, row.total_seconds, total_tracked, tty);

        if (format == .detail) {
            var title_count: u32 = 0;
            for (detail_rows) |dr| {
                if (title_count >= 3) break;
                if (!std.mem.eql(u8, dr.window_class[0..dr.class_len], name)) continue;
                const title = dr.window_title[0..dr.title_len];
                if (title.len == 0) continue;
                try printDetailTitle(writer, title, dr.total_seconds, tty);
                title_count += 1;
            }
        }
    }

    if (afk_seconds > 0) {
        try printAppRow(writer, "AFK", afk_seconds, total_tracked, tty);
    }

    // Footer
    try writeAnsi(writer, ansi.dim, tty);
    try writer.writeAll("─────────────────────────────────────────────────────────────────\n");
    try writeAnsi(writer, ansi.reset, tty);
    try writer.writeAll("  Total tracked:   ");
    try writeAnsi(writer, ansi.bold, tty);
    try printDuration(writer, total_tracked);
    try writeAnsi(writer, ansi.reset, tty);
    try writer.writeAll("\n\n");
}

fn showCsv(allocator: std.mem.Allocator, mode: ReportMode) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var database = db.Db.open(alloc) catch |err| {
        try std.io.getStdErr().writer().print("Failed to open database: {}\n", .{err});
        std.process.exit(1);
    };
    defer database.close();

    const now = std.time.timestamp();
    const range = getTimeRange(now, mode);
    const from = range[0];
    const to = range[1];

    const rows = try database.queryCsv(alloc, from, to);

    const writer = std.io.getStdOut().writer();

    try writer.writeAll("window_class,window_title,seconds\n");
    for (rows) |row| {
        const class = row.window_class[0..row.class_len];
        const title = row.window_title[0..row.title_len];
        try writeCsvField(writer, class);
        try writer.writeAll(",");
        try writeCsvField(writer, title);
        try writer.print(",{d}\n", .{row.total_seconds});
    }
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

const detail_col = 50; // column where duration starts (after 4-char indent)
const detail_max = detail_col - 4 - 2; // max display columns for title

/// Count approximate display width (codepoints, not bytes).
/// Skips UTF-8 continuation bytes (0x80..0xBF).
fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |byte| {
        if (byte & 0xC0 != 0x80) w += 1;
    }
    return w;
}

/// Find byte offset that corresponds to `max_cols` display columns.
fn truncateToWidth(s: []const u8, max_cols: usize) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) {
            if (cols >= max_cols) return i;
            cols += 1;
        }
    }
    return i;
}

fn printDetailTitle(writer: anytype, title: []const u8, secs: i64, tty: bool) !void {
    try writeAnsi(writer, ansi.dim, tty);
    try writer.writeAll("    ");
    const width = displayWidth(title);
    if (width <= detail_max) {
        try writer.writeAll(title);
        var pad: usize = detail_max + 2 - width;
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
    } else {
        const cut = truncateToWidth(title, detail_max - 3);
        try writer.writeAll(title[0..cut]);
        try writer.writeAll("...");
        try writer.writeAll("  ");
    }
    try printDuration(writer, secs);
    try writeAnsi(writer, ansi.reset, tty);
    try writer.writeAll("\n");
}

pub fn status(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var database = db.Db.open(alloc) catch |err| {
        try std.io.getStdErr().writer().print("Failed to open database: {}\n", .{err});
        std.process.exit(1);
    };
    defer database.close();

    const writer = std.io.getStdOut().writer();

    const tty = isatty();

    const latest = try database.getLatestActivity();
    if (latest) |act| {
        const now = std.time.timestamp();
        const age = now - act.end_time;

        if (age > 30) {
            try writeAnsi(writer, ansi.dim, tty);
            try writer.writeAll("Daemon is not running (no recent activity)\n");
            try writeAnsi(writer, ansi.reset, tty);
        } else {
            try writeAnsi(writer, ansi.bold, tty);
            try writer.print("Tracking: {s}", .{act.windowClass()});
            try writeAnsi(writer, ansi.reset, tty);
            if (act.windowTitle().len > 0) {
                try writeAnsi(writer, ansi.dim, tty);
                try writer.print(" — {s}", .{act.windowTitle()});
                try writeAnsi(writer, ansi.reset, tty);
            }
            try writer.writeAll("\n");
            try writer.writeAll("Duration: ");
            try writeAnsi(writer, ansi.bold, tty);
            try printDuration(writer, act.end_time - act.start_time);
            try writeAnsi(writer, ansi.reset, tty);
            try writer.writeAll("\n");
        }
    } else {
        try writer.writeAll("No activity recorded yet.\n");
    }
}

fn isatty() bool {
    return std.posix.isatty(std.io.getStdOut().handle);
}

const ansi = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const gray = "\x1b[90m";
};

fn writeAnsi(writer: anytype, code: []const u8, tty: bool) !void {
    if (tty) try writer.writeAll(code);
}

fn printDuration(writer: anytype, total_secs: i64) !void {
    const secs: u64 = @intCast(@max(total_secs, 0));
    const hours = secs / 3600;
    const mins = (secs % 3600) / 60;
    try writer.print("{d}h {d:0>2}m", .{ hours, mins });
}

const bar_width = 30;

fn printBar(writer: anytype, filled: u32, tty: bool) !void {
    try writeAnsi(writer, ansi.green, tty);
    var i: u32 = 0;
    while (i < bar_width) : (i += 1) {
        if (i < filled) {
            try writer.writeAll("\u{2588}");
        } else {
            if (i == filled) try writeAnsi(writer, ansi.gray, tty);
            try writer.writeAll("\u{2591}");
        }
    }
    try writeAnsi(writer, ansi.reset, tty);
}

fn printAppRow(writer: anytype, name: []const u8, secs: i64, total: i64, tty: bool) !void {
    if (total == 0) return;
    const pct: u32 = @intCast(@min(@divTrunc(secs * 100, total), 100));
    const bar_len: u32 = @intCast(@min(@divTrunc(secs * bar_width, total), bar_width));

    try writeAnsi(writer, ansi.bold, tty);
    try writer.print("  {s:<16}", .{name});
    try writeAnsi(writer, ansi.reset, tty);
    try writer.writeAll("  ");
    try printDuration(writer, secs);
    try writer.writeAll("  ");
    try printBar(writer, bar_len, tty);
    try writeAnsi(writer, ansi.dim, tty);
    try writer.print("  {d:>3}%", .{pct});
    try writeAnsi(writer, ansi.reset, tty);
    try writer.writeAll("\n");
}

fn getTimeRange(now: i64, mode: ReportMode) [2]i64 {
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
    // tm_wday: 0=Sunday. Convert to 0=Monday.
    const days_since_monday: i64 = if (tm.*.tm_wday == 0) 6 else @as(i64, tm.*.tm_wday) - 1;
    return day_start - (days_since_monday * 86400);
}

/// Parse "YYYY-MM-DD" into a unix timestamp at local midnight using mktime.
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
    tm.tm_isdst = -1; // let mktime figure out DST

    const result = c.mktime(&tm);
    if (result == -1) return error.InvalidDate;
    return @intCast(result);
}

/// Format a unix timestamp as a human-readable local date string.
fn formatDate(allocator: std.mem.Allocator, timestamp: i64) []const u8 {
    var t: c.time_t = @intCast(timestamp);
    const tm = c.localtime(&t) orelse return "???";
    var buf: [64]u8 = undefined;
    const len = c.strftime(&buf, buf.len, "%a %b %d, %Y", tm);
    if (len == 0) return "???";
    return allocator.dupe(u8, buf[0..len]) catch "???";
}

/// Format a time range as a readable label for report headers.
fn formatRangeLabel(allocator: std.mem.Allocator, from: i64, to: i64, mode: ReportMode) []const u8 {
    return switch (mode) {
        .today => formatDate(allocator, to),
        .week, .since => std.fmt.allocPrint(allocator, "{s} — {s}", .{
            formatDate(allocator, from),
            formatDate(allocator, to),
        }) catch "???",
    };
}

// --- tests ---

test "displayWidth ascii" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
}

test "displayWidth utf8" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("é")); // 2 bytes, 1 codepoint
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "truncateToWidth ascii" {
    try std.testing.expectEqual(@as(usize, 3), truncateToWidth("hello", 3));
    try std.testing.expectEqual(@as(usize, 5), truncateToWidth("hello", 10));
}

test "truncateToWidth utf8" {
    // "café" = 5 bytes (é is 2 bytes), 4 codepoints
    try std.testing.expectEqual(@as(usize, 3), truncateToWidth("café", 3)); // "caf"
    try std.testing.expectEqual(@as(usize, 5), truncateToWidth("café", 4)); // full string
}

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
