const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Activity = struct {
    id: i64,
    window_class_buf: [256]u8 = [_]u8{0} ** 256,
    window_class_len: usize = 0,
    window_title_buf: [256]u8 = [_]u8{0} ** 256,
    window_title_len: usize = 0,
    start_time: i64,
    end_time: i64,
    afk: bool,

    pub fn windowClass(self: *const Activity) []const u8 {
        return self.window_class_buf[0..self.window_class_len];
    }

    pub fn windowTitle(self: *const Activity) []const u8 {
        return self.window_title_buf[0..self.window_title_len];
    }
};

pub const ReportRow = struct {
    window_class: [256]u8 = [_]u8{0} ** 256,
    class_len: usize = 0,
    total_seconds: i64 = 0,
};

pub const DetailRow = struct {
    window_class: [256]u8 = [_]u8{0} ** 256,
    class_len: usize = 0,
    window_title: [256]u8 = [_]u8{0} ** 256,
    title_len: usize = 0,
    total_seconds: i64 = 0,
};

pub const CsvRow = struct {
    window_class: [256]u8 = [_]u8{0} ** 256,
    class_len: usize = 0,
    window_title: [256]u8 = [_]u8{0} ** 256,
    title_len: usize = 0,
    start_time: i64 = 0,
    duration: i64 = 0,
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator) !Db {
        const db_path = try getDbPath(allocator);

        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(db_path.ptr, &handle) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.DbOpen;
        }

        var self = Db{ .handle = handle.? };
        try self.migrate();
        return self;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn migrate(self: *Db) !void {
        // WAL allows concurrent reads while the daemon writes
        _ = c.sqlite3_exec(self.handle, "PRAGMA journal_mode=WAL;", null, null, null);

        const sql =
            \\CREATE TABLE IF NOT EXISTS activities (
            \\    id           INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    window_class TEXT NOT NULL,
            \\    window_title TEXT NOT NULL,
            \\    start_time   INTEGER NOT NULL,
            \\    end_time     INTEGER NOT NULL,
            \\    afk          INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_activities_time
            \\    ON activities(start_time, end_time);
        ;
        if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK) {
            return error.DbMigrate;
        }
    }

    /// Insert a new activity row.
    pub fn insertActivity(self: *Db, class: []const u8, title: []const u8, now: i64, afk: bool) !i64 {
        const sql = "INSERT INTO activities (window_class, window_title, start_time, end_time, afk) VALUES (?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, class.ptr, @intCast(class.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, title.ptr, @intCast(title.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(stmt, 3, now);
        _ = c.sqlite3_bind_int64(stmt, 4, now);
        _ = c.sqlite3_bind_int(stmt, 5, if (afk) 1 else 0);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.DbInsert;
        }

        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Extend the end_time of an existing activity row.
    pub fn extendActivity(self: *Db, id: i64, end_time: i64) !void {
        const sql = "UPDATE activities SET end_time = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, end_time);
        _ = c.sqlite3_bind_int64(stmt, 2, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.DbUpdate;
        }
    }

    /// Query aggregated time per window_class in a time range.
    pub fn queryReport(self: *Db, allocator: std.mem.Allocator, from: i64, to: i64) ![]ReportRow {
        const sql =
            \\SELECT window_class,
            \\       SUM(MIN(end_time, ?) - MAX(start_time, ?)) as total
            \\FROM activities
            \\WHERE end_time > ? AND start_time < ? AND afk = 0
            \\GROUP BY window_class
            \\ORDER BY total DESC
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, to);
        _ = c.sqlite3_bind_int64(stmt, 2, from);
        _ = c.sqlite3_bind_int64(stmt, 3, from);
        _ = c.sqlite3_bind_int64(stmt, 4, to);

        var rows = std.ArrayList(ReportRow).init(allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var row = ReportRow{};
            const class_ptr = c.sqlite3_column_text(stmt, 0);
            const class_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const copy_len = @min(class_len, row.window_class.len);
            if (class_ptr) |p| {
                @memcpy(row.window_class[0..copy_len], p[0..copy_len]);
            }
            row.class_len = copy_len;
            row.total_seconds = c.sqlite3_column_int64(stmt, 1);
            try rows.append(row);
        }

        return rows.toOwnedSlice();
    }

    /// Query total AFK time in a range.
    pub fn queryAfkTime(self: *Db, from: i64, to: i64) !i64 {
        const sql =
            \\SELECT COALESCE(SUM(MIN(end_time, ?) - MAX(start_time, ?)), 0)
            \\FROM activities
            \\WHERE end_time > ? AND start_time < ? AND afk = 1
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, to);
        _ = c.sqlite3_bind_int64(stmt, 2, from);
        _ = c.sqlite3_bind_int64(stmt, 3, from);
        _ = c.sqlite3_bind_int64(stmt, 4, to);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            return c.sqlite3_column_int64(stmt, 0);
        }
        return 0;
    }

    /// Query top titles per class, ranked by time. Used for --detail view.
    pub fn queryDetail(self: *Db, allocator: std.mem.Allocator, from: i64, to: i64) ![]DetailRow {
        return self.queryDetailRows(allocator, from, to,
            \\SELECT window_class, window_title,
            \\       SUM(MIN(end_time, ?) - MAX(start_time, ?)) as total
            \\FROM activities
            \\WHERE end_time > ? AND start_time < ? AND afk = 0
            \\GROUP BY window_class, window_title
            \\ORDER BY window_class, total DESC
        );
    }

    /// Query individual rows for CSV export (class, title, start_time, duration). Includes AFK.
    pub fn queryCsv(self: *Db, allocator: std.mem.Allocator, from: i64, to: i64) ![]CsvRow {
        const sql =
            \\SELECT window_class, window_title,
            \\       MAX(start_time, ?) as clamped_start,
            \\       MIN(end_time, ?) - MAX(start_time, ?) as duration
            \\FROM activities
            \\WHERE end_time > ? AND start_time < ?
            \\ORDER BY start_time ASC
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, from);
        _ = c.sqlite3_bind_int64(stmt, 2, to);
        _ = c.sqlite3_bind_int64(stmt, 3, from);
        _ = c.sqlite3_bind_int64(stmt, 4, from);
        _ = c.sqlite3_bind_int64(stmt, 5, to);

        var rows = std.ArrayList(CsvRow).init(allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var row = CsvRow{};

            const class_ptr = c.sqlite3_column_text(stmt, 0);
            const class_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const cl = @min(class_len, row.window_class.len);
            if (class_ptr) |p| @memcpy(row.window_class[0..cl], p[0..cl]);
            row.class_len = cl;

            const title_ptr = c.sqlite3_column_text(stmt, 1);
            const title_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const tl = @min(title_len, row.window_title.len);
            if (title_ptr) |p| @memcpy(row.window_title[0..tl], p[0..tl]);
            row.title_len = tl;

            row.start_time = c.sqlite3_column_int64(stmt, 2);
            row.duration = c.sqlite3_column_int64(stmt, 3);
            try rows.append(row);
        }

        return rows.toOwnedSlice();
    }

    fn queryDetailRows(self: *Db, allocator: std.mem.Allocator, from: i64, to: i64, sql: [*:0]const u8) ![]DetailRow {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, to);
        _ = c.sqlite3_bind_int64(stmt, 2, from);
        _ = c.sqlite3_bind_int64(stmt, 3, from);
        _ = c.sqlite3_bind_int64(stmt, 4, to);

        var rows = std.ArrayList(DetailRow).init(allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var row = DetailRow{};

            const class_ptr = c.sqlite3_column_text(stmt, 0);
            const class_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
            const cl = @min(class_len, row.window_class.len);
            if (class_ptr) |p| @memcpy(row.window_class[0..cl], p[0..cl]);
            row.class_len = cl;

            const title_ptr = c.sqlite3_column_text(stmt, 1);
            const title_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const tl = @min(title_len, row.window_title.len);
            if (title_ptr) |p| @memcpy(row.window_title[0..tl], p[0..tl]);
            row.title_len = tl;

            row.total_seconds = c.sqlite3_column_int64(stmt, 2);
            try rows.append(row);
        }

        return rows.toOwnedSlice();
    }

    /// Get the most recent activity (for status command).
    pub fn getLatestActivity(self: *Db) !?Activity {
        const sql = "SELECT id, window_class, window_title, start_time, end_time, afk FROM activities ORDER BY end_time DESC LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.DbPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var act = Activity{
                .id = c.sqlite3_column_int64(stmt, 0),
                .start_time = c.sqlite3_column_int64(stmt, 3),
                .end_time = c.sqlite3_column_int64(stmt, 4),
                .afk = c.sqlite3_column_int(stmt, 5) != 0,
            };

            const class_ptr = c.sqlite3_column_text(stmt, 1);
            const class_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const cl = @min(class_len, act.window_class_buf.len);
            if (class_ptr) |p| @memcpy(act.window_class_buf[0..cl], p[0..cl]);
            act.window_class_len = cl;

            const title_ptr = c.sqlite3_column_text(stmt, 2);
            const title_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
            const tl = @min(title_len, act.window_title_buf.len);
            if (title_ptr) |p| @memcpy(act.window_title_buf[0..tl], p[0..tl]);
            act.window_title_len = tl;

            return act;
        }
        return null;
    }

    fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
        const state_home = std.posix.getenv("XDG_STATE_HOME");
        const dir = if (state_home) |xdg|
            try std.fmt.allocPrint(allocator, "{s}/ebyt", .{xdg})
        else blk: {
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            break :blk try std.fmt.allocPrint(allocator, "{s}/.local/state/ebyt", .{home});
        };
        defer allocator.free(dir);

        std.fs.cwd().makePath(dir) catch return error.MkDir;

        return try std.fmt.allocPrintZ(allocator, "{s}/ebyt.db", .{dir});
    }

    fn openMemory() !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(":memory:", &handle) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.DbOpen;
        }
        var self = Db{ .handle = handle.? };
        try self.migrate();
        return self;
    }
};

// --- tests ---

test "insert and extend activity" {
    var database = try Db.openMemory();
    defer database.close();

    const id = try database.insertActivity("firefox", "GitHub", 1000, false);
    try database.extendActivity(id, 1010);

    const act = (try database.getLatestActivity()).?;
    try std.testing.expectEqualStrings("firefox", act.windowClass());
    try std.testing.expectEqual(@as(i64, 1000), act.start_time);
    try std.testing.expectEqual(@as(i64, 1010), act.end_time);
}

test "queryReport aggregates by class" {
    var database = try Db.openMemory();
    defer database.close();

    _ = try database.insertActivity("firefox", "tab1", 1000, false);
    try database.extendActivity(1, 1060);
    _ = try database.insertActivity("Alacritty", "~", 1060, false);
    try database.extendActivity(2, 1090);

    const rows = try database.queryReport(std.testing.allocator, 0, 2000);
    defer std.testing.allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("firefox", rows[0].window_class[0..rows[0].class_len]);
    try std.testing.expectEqualStrings("Alacritty", rows[1].window_class[0..rows[1].class_len]);
}

test "queryAfkTime only counts afk rows" {
    var database = try Db.openMemory();
    defer database.close();

    _ = try database.insertActivity("firefox", "", 1000, false);
    try database.extendActivity(1, 1060);
    _ = try database.insertActivity("AFK", "", 1060, true);
    try database.extendActivity(2, 1120);

    const afk = try database.queryAfkTime(0, 2000);
    try std.testing.expectEqual(@as(i64, 60), afk);
}
