// ebyt tui — interactive activity dashboard
//
// Elm architecture: Model holds state, Msg describes events,
// update transitions state, view renders immutably.
// Tufte: high data-ink ratio, direct labeling, no chartjunk.

const std = @import("std");
const zz = @import("zigzag");
const db = @import("db.zig");
const ct = @cImport(@cInclude("time.h"));

// -- Theme --

const Color = zz.Color;

const orange = Color.fromRgb(255, 107, 53);
const yellow = Color.fromRgb(255, 210, 63);
const cyan = Color.fromRgb(6, 214, 160);
const magenta = Color.fromRgb(255, 63, 160);
const dim = Color.fromRgb(80, 80, 100);
const fg = Color.fromRgb(224, 221, 212);
const afk_color = Color.fromRgb(74, 74, 90);

const app_palette = [_]Color{
    orange,
    cyan,
    Color.fromRgb(17, 138, 178),
    magenta,
    yellow,
    Color.fromRgb(155, 93, 229),
    Color.fromRgb(241, 91, 181),
    Color.fromRgb(239, 71, 111),
};

// -- Layout constants --

const max_w: u16 = 96; // cap layout width so nothing overflows
const name_col: usize = 18; // app name column width
const bar_col: usize = 24; // fixed app bar width

// -- Data --

const ViewMode = enum { day, week };

const HourBucket = struct {
    active: i64 = 0,
    afk: i64 = 0,
};

const max_apps = 32;

const Data = struct {
    rows: []db.ReportRow = &.{},
    details: []db.DetailRow = &.{},
    afk_secs: i64 = 0,
    total_active: i64 = 0,
    hourly: [24]HourBucket = [_]HourBucket{.{}} ** 24,
    daily: [7]HourBucket = [_]HourBucket{.{}} ** 7,
};

// -- Model --

pub const Model = struct {
    pub const Msg = union(enum) {
        key: zz.msg.Key,
        window_size: zz.msg.WindowSize,
    };

    database: ?db.Db = null,
    data_arena: ?std.heap.ArenaAllocator = null,
    day_ts: i64 = 0,
    mode: ViewMode = .day,
    cursor: usize = 0,
    expanded: [max_apps]bool = [_]bool{false} ** max_apps,
    data: Data = .{},
    err: bool = false,

    // -- init / deinit --

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.database = db.Db.open(ctx.persistent_allocator) catch {
            self.err = true;
            return .none;
        };
        self.data_arena = std.heap.ArenaAllocator.init(ctx.persistent_allocator);
        self.day_ts = startOfDay(std.time.timestamp());
        self.reload();
        return .none;
    }

    pub fn deinit(self: *Model) void {
        if (self.data_arena) |*a| a.deinit();
        if (self.database) |*d| d.close();
    }

    // -- update --

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        return switch (msg) {
            .key => |k| self.onKey(k),
            .window_size => .none,
        };
    }

    fn onKey(self: *Model, k: zz.msg.Key) zz.Cmd(Msg) {
        if (k.event_type == .release) return .none;
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                'h' => self.nav(-1),
                'l' => self.nav(1),
                'j' => self.move(1),
                'k' => self.move(-1),
                ' ' => {
                    if (self.cursor < max_apps) self.expanded[self.cursor] = !self.expanded[self.cursor];
                },
                else => {},
            },
            .left => self.nav(-1),
            .right => self.nav(1),
            .up => self.move(-1),
            .down => self.move(1),
            .tab => {
                self.mode = if (self.mode == .day) .week else .day;
                self.resetCursor();
                self.reload();
            },
            .enter => {
                if (self.cursor < max_apps) self.expanded[self.cursor] = !self.expanded[self.cursor];
            },
            else => {},
        }
        return .none;
    }

    fn nav(self: *Model, dir: i2) void {
        const step: i64 = if (self.mode == .day) 86400 else 7 * 86400;
        const next = self.day_ts + @as(i64, dir) * step;
        if (dir > 0 and next > startOfDay(std.time.timestamp())) return;
        self.day_ts = next;
        self.resetCursor();
        self.reload();
    }

    fn move(self: *Model, dir: i2) void {
        const len = @min(self.data.rows.len, max_apps);
        if (len == 0) return;
        if (dir > 0 and self.cursor < len - 1) {
            self.cursor += 1;
        } else if (dir < 0 and self.cursor > 0) {
            self.cursor -= 1;
        }
    }

    fn resetCursor(self: *Model) void {
        self.cursor = 0;
        self.expanded = [_]bool{false} ** max_apps;
    }

    fn reload(self: *Model) void {
        if (self.data_arena) |*arena| _ = arena.reset(.retain_capacity);
        const a = if (self.data_arena) |*arena| arena.allocator() else return;
        var database = self.database orelse return;
        self.data = queryData(&database, a, self.day_ts, self.mode) catch .{};
    }

    // -- view --

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;
        const w = @min(ctx.width, max_w);
        const h = ctx.height;

        if (self.err) {
            return (zz.Style{}).fg(orange).render(a, "  Database error. Press q to quit.") catch "";
        }

        const header = viewHeader(a, self.day_ts, self.mode, ctx.width) catch return "";
        const stats = viewStats(a, self.data) catch return "";
        const timeline = viewTimeline(a, self.data, self.mode, self.day_ts, w) catch return "";

        const used = zz.height(header) + zz.height(stats) + zz.height(timeline);
        const apps_h: usize = if (@as(usize, h) > used + 2) @as(usize, h) - used else 4;
        const apps = viewApps(a, self.data, self.cursor, &self.expanded, w, apps_h) catch return "";

        const body = zz.joinVertical(a, &.{ header, stats, timeline, apps }) catch return "";
        return zz.placeVertical(a, @as(usize, h), .top, body) catch body;
    }
};

// -- View: header --

fn viewHeader(a: std.mem.Allocator, day_ts: i64, mode: ViewMode, full_w: u16) ![]const u8 {
    const S = zz.Style;
    const hw = full_w -| 1; // 1-char right margin to avoid cursor wrap

    const orn = try (S{}).fg(dim).render(a, "\xe2\x96\x91\xe2\x96\x92\xe2\x96\x93");
    const name = try (S{}).fg(cyan).bold(true).render(a, "E B Y T");
    const orn2 = try (S{}).fg(dim).render(a, "\xe2\x96\x93\xe2\x96\x92\xe2\x96\x91");
    const left = try std.fmt.allocPrint(a, "  {s} {s} {s}", .{ orn, name, orn2 });
    const help = try (S{}).fg(dim).render(a, "q:quit  tab:view  \xe2\x86\x90\xe2\x86\x92:nav  jk:sel  \xe2\x86\xb5:expand");
    const title_line = try alignLR(a, left, help, hw);

    const step: i64 = if (mode == .day) 86400 else 7 * 86400;
    const is_now = day_ts + step > startOfDay(std.time.timestamp());

    const al = try (S{}).fg(orange).render(a, "\xe2\x97\x84");
    const date_style = (S{}).fg(fg).bold(true);
    const date = try date_style.render(a, try fmtDateRange(a, day_ts, mode));
    const nav_left = if (is_now)
        try std.fmt.allocPrint(a, "  {s} {s}", .{ al, date })
    else blk: {
        const ar = try (S{}).fg(orange).render(a, "\xe2\x96\xba");
        break :blk try std.fmt.allocPrint(a, "  {s} {s} {s}", .{ al, date, ar });
    };

    const view_label = blk: {
        if (mode == .day) {
            const on = try (S{}).fg(yellow).bold(true).render(a, "[DAY]");
            const off = try (S{}).fg(dim).render(a, " / week");
            break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ on, off });
        } else {
            const off = try (S{}).fg(dim).render(a, "day / ");
            const on = try (S{}).fg(yellow).bold(true).render(a, "[WEEK]");
            break :blk try std.fmt.allocPrint(a, "{s}{s}", .{ off, on });
        }
    };
    const nav_line = try alignLR(a, nav_left, view_label, hw);

    return zz.joinVertical(a, &.{ "", title_line, "", nav_line, "" });
}

// -- View: stats --
// Fixed-width durations so the box doesn't jump when navigating.

fn viewStats(a: std.mem.Allocator, data: Data) ![]const u8 {
    const S = zz.Style;
    const lbl = (S{}).fg(dim);
    const total = data.total_active + data.afk_secs;

    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;

    const content = try std.fmt.allocPrint(a, "{s} {s}    {s} {s}    {s} {s}", .{
        try lbl.render(a, "ACTIVE"), try (S{}).fg(cyan).bold(true).render(a, fmtDurFixed(&b1, data.total_active)),
        try lbl.render(a, "AFK"),    try (S{}).fg(orange).bold(true).render(a, fmtDurFixed(&b2, data.afk_secs)),
        try lbl.render(a, "TOTAL"),  try (S{}).fg(yellow).bold(true).render(a, fmtDurFixed(&b3, total)),
    });

    return try (S{})
        .borderAll(zz.Border.rounded)
        .borderForeground(dim)
        .paddingLeft(1).paddingRight(1)
        .marginLeft(2)
        .render(a, content);
}

// -- View: timeline --
// Stacked bars: active █ on bottom, AFK ░ on top.
// Day: 24 columns (hours). Week: 7 columns (days, domain scales to data).

fn viewTimeline(a: std.mem.Allocator, data: Data, mode: ViewMode, day_ts: i64, w: u16) ![]const u8 {
    const S = zz.Style;
    const label_text = if (mode == .day) "hourly pulse" else "daily pulse";
    const sec_hdr = try sectionHeader(a, label_text, cyan, w);

    const chart_str = switch (mode) {
        .day => try buildDayChart(a, data, w),
        .week => try buildWeekChart(a, data, day_ts, w),
    };

    const leg = try std.fmt.allocPrint(a, "     {s} {s}  {s} {s}", .{
        try (S{}).fg(cyan).render(a, "\xe2\x96\x88"),
        try (S{}).fg(dim).render(a, "active"),
        try (S{}).fg(afk_color).render(a, "\xe2\x96\x91"),
        try (S{}).fg(dim).render(a, "afk"),
    });

    return zz.joinVertical(a, &.{ sec_hdr, chart_str, leg, "" });
}

fn buildDayChart(a: std.mem.Allocator, data: Data, w: u16) ![]const u8 {
    const n: u16 = 24;
    const gap: u16 = 1;
    const bw: u16 = @max(1, (w -| n * gap) / n);

    var bars: [24]StackedBar = undefined;
    for (0..24) |h| {
        const bucket = data.hourly[h];
        bars[h] = .{
            .active_secs = bucket.active,
            .afk_secs = bucket.afk,
            .label = try std.fmt.allocPrint(a, "{d:0>2}", .{h}),
        };
    }
    return renderStackedChart(a, &bars, 7, 3600, bw, gap);
}

fn buildWeekChart(a: std.mem.Allocator, data: Data, day_ts: i64, w: u16) ![]const u8 {
    const n: u16 = 7;
    const gap: u16 = 1;
    const bw: u16 = @max(1, (w -| n * gap) / n);
    const ws = startOfWeek(day_ts);

    var bars: [7]StackedBar = undefined;
    var max_total: i64 = 0;
    for (0..7) |d| {
        const bucket = data.daily[d];
        const stamp = ws + @as(i64, @intCast(d)) * 86400;
        var name_buf: [16]u8 = undefined;
        const full_name = fmtDayName(&name_buf, stamp);
        bars[d] = .{
            .active_secs = bucket.active,
            .afk_secs = bucket.afk,
            .label = try a.dupe(u8, full_name[0..@min(full_name.len, 3)]),
        };
        max_total = @max(max_total, bucket.active + bucket.afk);
    }
    // Domain: at least 10h, scales up to fit the busiest day
    const domain: f64 = @floatFromInt(@max(max_total, 10 * 3600));
    return renderStackedChart(a, &bars, 7, domain, bw, gap);
}

const StackedBar = struct {
    active_secs: i64,
    afk_secs: i64,
    label: []const u8,
};

/// Render a stacked bar chart: active █ on bottom, AFK ░ on top, baseline ─ for empty.
fn renderStackedChart(
    a: std.mem.Allocator,
    bars: []const StackedBar,
    chart_h: u16,
    domain: f64,
    bw: u16,
    gap_w: u16,
) ![]const u8 {
    const S = zz.Style;
    const h_f: f64 = @floatFromInt(chart_h);
    const bottom: usize = @as(usize, chart_h) - 1;
    var lines = std.ArrayList([]const u8){};

    for (0..chart_h) |row| {
        var line = std.ArrayList(u8){};
        for (bars, 0..) |bar, i| {
            const act_f: f64 = @floatFromInt(@max(bar.active_secs, 0));
            const tot_f: f64 = @floatFromInt(@max(bar.active_secs + bar.afk_secs, 0));
            const active_rows: usize = @intFromFloat(@min(@round(act_f / domain * h_f), h_f));
            const total_rows: usize = @intFromFloat(@min(@round(tot_f / domain * h_f), h_f));
            const active_top = @as(usize, chart_h) - active_rows;
            const afk_top = @as(usize, chart_h) - total_rows;

            if (row >= active_top and active_rows > 0) {
                try line.appendSlice(a, try (S{}).fg(cyan).render(a, try repeatStr(a, "\xe2\x96\x88", bw)));
            } else if (row >= afk_top and total_rows > active_rows) {
                try line.appendSlice(a, try (S{}).fg(afk_color).render(a, try repeatStr(a, "\xe2\x96\x91", bw)));
            } else if (row == bottom) {
                try line.appendSlice(a, try (S{}).fg(dim).render(a, try repeatStr(a, "\xe2\x94\x80", bw)));
            } else {
                try line.appendNTimes(a, ' ', bw);
            }

            if (i < bars.len - 1) {
                if (row == bottom) {
                    try line.appendSlice(a, try (S{}).fg(dim).render(a, try repeatStr(a, "\xe2\x94\x80", gap_w)));
                } else {
                    try line.appendNTimes(a, ' ', gap_w);
                }
            }
        }
        try lines.append(a, try line.toOwnedSlice(a));
    }

    // Label row
    var lbl = std.ArrayList(u8){};
    for (bars, 0..) |bar, i| {
        const lw = @min(bar.label.len, @as(usize, bw));
        const pad_l = (@as(usize, bw) -| lw) / 2;
        const pad_r = @as(usize, bw) -| lw -| pad_l;
        try lbl.appendNTimes(a, ' ', pad_l);
        try lbl.appendSlice(a, try (S{}).fg(dim).render(a, bar.label[0..lw]));
        try lbl.appendNTimes(a, ' ', pad_r);
        if (i < bars.len - 1) try lbl.appendNTimes(a, ' ', gap_w);
    }
    try lines.append(a, try lbl.toOwnedSlice(a));

    return zz.joinVertical(a, try lines.toOwnedSlice(a));
}

// -- View: applications --
// Fixed bar width, duration right-aligned
//   ▸ name______________  ████████████████████████   Xh XXm

fn viewApps(a: std.mem.Allocator, data: Data, cursor: usize, expanded: *const [max_apps]bool, w: u16, max_h: usize) ![]const u8 {
    const S = zz.Style;
    const total = data.total_active + data.afk_secs;
    const sec_hdr = try sectionHeader(a, "applications", magenta, w);

    var lines = std.ArrayList([]const u8){};

    if (total == 0) {
        return zz.joinVertical(a, &.{ sec_hdr, try (S{}).fg(dim).render(a, "    No activity recorded.") });
    }

    var cursor_line_start: usize = 0;
    var cursor_line_end: usize = 0;

    for (data.rows, 0..) |row, i| {
        if (i >= max_apps) break;
        const name = row.window_class[0..row.class_len];
        const filled: usize = @intCast(@min(@divTrunc(row.total_seconds * @as(i64, bar_col), total), @as(i64, bar_col)));
        const color = app_palette[i % app_palette.len];
        const sel = i == cursor;
        const exp = if (i < max_apps) expanded[i] else false;

        if (i == cursor) cursor_line_start = lines.items.len;

        const ind = if (sel)
            try (S{}).fg(yellow).render(a, if (exp) "\xe2\x96\xbe" else "\xe2\x96\xb8")
        else
            " ";

        const name_styled = try (if (sel) (S{}).fg(color).bold(true) else (S{}).fg(color))
            .render(a, try fitWidth(a, name, name_col));

        const bar_fill = try (S{}).fg(color).render(a, try repeatStr(a, "\xe2\x96\x88", filled));
        const bar_empty = try (S{}).fg(dim).render(a, try repeatStr(a, "\xe2\x96\x91", bar_col -| filled));

        var dbuf: [16]u8 = undefined;
        const dur = try (S{}).fg(dim).render(a, fmtDurFixed(&dbuf, row.total_seconds));

        try lines.append(a, try std.fmt.allocPrint(a, "  {s} {s}  {s}{s}  {s}", .{
            ind, name_styled, bar_fill, bar_empty, dur,
        }));

        if (exp) {
            var count: u32 = 0;
            for (data.details) |dr| {
                if (count >= 5) break;
                if (!std.mem.eql(u8, dr.window_class[0..dr.class_len], name)) continue;
                const title = dr.window_title[0..dr.title_len];
                if (title.len == 0) continue;

                const max_tw: usize = if (w > 34) @as(usize, w) - 34 else 40;
                const pipe = try (S{}).fg(dim).render(a, "\xe2\x94\x8a");
                const title_s = try (S{}).fg(fg).dim(true).render(a, try fitWidth(a, title, max_tw));
                var dd: [16]u8 = undefined;
                const ddur = try (S{}).fg(dim).render(a, fmtDurFixed(&dd, dr.total_seconds));
                try lines.append(a, try std.fmt.allocPrint(a, "     {s} {s}  {s}", .{ pipe, title_s, ddur }));
                count += 1;
            }
        }

        if (i == cursor) cursor_line_end = lines.items.len;
    }

    // AFK row
    if (data.afk_secs > 0) {
        const filled: usize = @intCast(@min(@divTrunc(data.afk_secs * @as(i64, bar_col), total), @as(i64, bar_col)));
        const afk_name = try (S{}).fg(afk_color).render(a, try fitWidth(a, "AFK", name_col));
        const afk_bar = try (S{}).fg(afk_color).render(a, try repeatStr(a, "\xe2\x96\x91", filled));
        const afk_empty = try (S{}).fg(dim).render(a, try repeatStr(a, "\xc2\xb7", bar_col -| filled));
        var dbuf: [16]u8 = undefined;
        const afk_dur = try (S{}).fg(dim).render(a, fmtDurFixed(&dbuf, data.afk_secs));
        try lines.append(a, try std.fmt.allocPrint(a, "    {s}  {s}{s}  {s}", .{
            afk_name, afk_bar, afk_empty, afk_dur,
        }));
    }

    // Scroll window: limit visible rows to fit terminal height
    const all = lines.items;
    const avail = if (max_h > 1) max_h - 1 else 1; // -1 for section header

    if (all.len <= avail) {
        var result = std.ArrayList([]const u8){};
        try result.append(a, sec_hdr);
        for (all) |line| try result.append(a, line);
        return zz.joinVertical(a, try result.toOwnedSlice(a));
    }

    // Reserve space for scroll indicators
    const vis = @max(avail -| 2, 1);
    var offset: usize = 0;
    if (cursor_line_end > vis) offset = cursor_line_end - vis;
    if (cursor_line_start < offset) offset = cursor_line_start;
    const end = @min(offset + vis, all.len);

    var result = std.ArrayList([]const u8){};
    try result.append(a, sec_hdr);
    if (offset > 0)
        try result.append(a, try (S{}).fg(dim).render(a, try std.fmt.allocPrint(a, "    \xe2\x86\x91 {d} more", .{offset})));
    for (all[offset..end]) |line| try result.append(a, line);
    if (end < all.len)
        try result.append(a, try (S{}).fg(dim).render(a, try std.fmt.allocPrint(a, "    \xe2\x86\x93 {d} more", .{all.len - end})));
    return zz.joinVertical(a, try result.toOwnedSlice(a));
}

// -- View helpers --

fn sectionHeader(a: std.mem.Allocator, label: []const u8, color: Color, w: u16) ![]const u8 {
    const S = zz.Style;
    const prefix_dw = 5 + zz.width(label) + 1;
    const rest = if (@as(usize, w) > prefix_dw) @as(usize, w) - prefix_dw else 4;
    const sep = try (S{}).fg(dim).render(a, "\xe2\x94\x80\xe2\x94\x80");
    const styled = try (S{}).fg(color).render(a, label);
    const trail = try (S{}).fg(dim).render(a, try repeatStr(a, "\xe2\x94\x80", rest));
    return std.fmt.allocPrint(a, "  {s} {s} {s}", .{ sep, styled, trail });
}

fn alignLR(a: std.mem.Allocator, left: []const u8, right: []const u8, total: u16) ![]const u8 {
    const lw = zz.width(left);
    const rw = zz.width(right);
    const tw: usize = @intCast(total);
    const used = lw + rw;
    if (tw > used) {
        const pad = try a.alloc(u8, tw - used);
        @memset(pad, ' ');
        return std.fmt.allocPrint(a, "{s}{s}{s}", .{ left, pad, right });
    }
    return std.fmt.allocPrint(a, "{s} {s}", .{ left, right });
}

fn fitWidth(a: std.mem.Allocator, text: []const u8, target: usize) ![]const u8 {
    const w = zz.width(text);
    if (w == target) return text;
    if (w < target) return zz.measure.padRight(a, text, target);
    return zz.measure.truncate(a, text, target);
}

fn repeatStr(a: std.mem.Allocator, char: []const u8, n: usize) ![]const u8 {
    if (n == 0) return "";
    const buf = try a.alloc(u8, char.len * n);
    for (0..n) |i| @memcpy(buf[i * char.len .. (i + 1) * char.len], char);
    return buf;
}

// -- Data queries --

fn queryData(database: *db.Db, a: std.mem.Allocator, day_ts: i64, mode: ViewMode) !Data {
    const from = if (mode == .day) day_ts else startOfWeek(day_ts);
    const to = if (mode == .day) day_ts + 86400 else startOfWeek(day_ts) + 7 * 86400;
    const now = std.time.timestamp();
    const end = @min(to, now + 1);

    const rows = try database.queryReport(a, from, end);
    const details = try database.queryDetail(a, from, end);
    const afk_secs = try database.queryAfkTime(from, end);
    const intervals = try database.queryIntervals(a, from, end);

    var total_active: i64 = 0;
    for (rows) |r| total_active += r.total_seconds;

    var hourly = [_]HourBucket{.{}} ** 24;
    var daily = [_]HourBucket{.{}} ** 7;
    for (intervals) |iv| bucketInterval(&hourly, &daily, iv, from);

    return .{
        .rows = rows,
        .details = details,
        .afk_secs = afk_secs,
        .total_active = total_active,
        .hourly = hourly,
        .daily = daily,
    };
}

fn bucketInterval(hourly: *[24]HourBucket, daily: *[7]HourBucket, iv: db.Interval, range_start: i64) void {
    var cursor = iv.start_time;
    while (cursor < iv.end_time) {
        var t: ct.time_t = @intCast(cursor);
        const tm = ct.localtime(&t) orelse return;
        const h: usize = @intCast(tm.*.tm_hour);
        const into = @as(i64, tm.*.tm_min) * 60 + @as(i64, tm.*.tm_sec);
        const next = cursor + (3600 - into);
        const chunk_end = @min(iv.end_time, next);
        const secs = chunk_end - cursor;

        if (iv.afk) hourly[h].afk += secs else hourly[h].active += secs;

        const day = startOfDay(cursor);
        // divFloor is safe: both are local midnights, DST shifts ≤1h, rounds correctly.
        const di = @divFloor(day - range_start, 86400);
        if (di >= 0 and di < 7) {
            const idx: usize = @intCast(di);
            if (iv.afk) daily[idx].afk += secs else daily[idx].active += secs;
        }
        cursor = chunk_end;
    }
}

// -- Time helpers --

fn startOfDay(ts: i64) i64 {
    var t: ct.time_t = @intCast(ts);
    const tm = ct.localtime(&t) orelse return ts - @mod(ts, 86400);
    return ts - @as(i64, tm.*.tm_hour) * 3600 - @as(i64, tm.*.tm_min) * 60 - @as(i64, tm.*.tm_sec);
}

fn startOfWeek(ts: i64) i64 {
    const d = startOfDay(ts);
    var t: ct.time_t = @intCast(d);
    const tm = ct.localtime(&t) orelse return d;
    const since_mon: i64 = if (tm.*.tm_wday == 0) 6 else @as(i64, tm.*.tm_wday) - 1;
    return d - since_mon * 86400;
}

fn fmtDate(buf: []u8, ts: i64) []const u8 {
    var t: ct.time_t = @intCast(ts);
    const tm = ct.localtime(&t) orelse return "???";
    const n = ct.strftime(buf.ptr, buf.len, "%a %b %d, %Y", tm);
    return if (n > 0) buf[0..n] else "???";
}

fn fmtShortDate(buf: []u8, ts: i64) []const u8 {
    var t: ct.time_t = @intCast(ts);
    const tm = ct.localtime(&t) orelse return "???";
    const n = ct.strftime(buf.ptr, buf.len, "%a %d", tm);
    return if (n > 0) buf[0..n] else "???";
}

fn fmtDayName(buf: []u8, ts: i64) []const u8 {
    var t: ct.time_t = @intCast(ts);
    const tm = ct.localtime(&t) orelse return "???";
    const n = ct.strftime(buf.ptr, buf.len, "%A", tm);
    return if (n > 0) buf[0..n] else "???";
}

fn fmtDateRange(a: std.mem.Allocator, ts: i64, mode: ViewMode) ![]const u8 {
    if (mode == .day) {
        var buf: [64]u8 = undefined;
        return try a.dupe(u8, fmtDate(&buf, ts));
    } else {
        const ws = startOfWeek(ts);
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        return std.fmt.allocPrint(a, "{s} \xe2\x80\x94 {s}", .{
            fmtShortDate(&b1, ws),
            fmtShortDate(&b2, ws + 6 * 86400),
        });
    }
}

/// Fixed-width duration for stats box: always " Xh XXm" (7 chars)
fn fmtDurFixed(buf: []u8, secs: i64) []const u8 {
    const s: u64 = @intCast(@max(secs, 0));
    const h = s / 3600;
    const m = (s % 3600) / 60;
    return std.fmt.bufPrint(buf, "{d:>2}h {d:0>2}m", .{ h, m }) catch "???";
}

// -- Entry point --

pub fn run(allocator: std.mem.Allocator) !void {
    var p = try zz.Program(Model).initWithOptions(allocator, .{
        .fps = 30,
        .title = "ebyt",
    });
    defer p.deinit();
    try p.run();
}

// -- tests --

test "bucketInterval totals match interval duration" {
    var hourly = [_]HourBucket{.{}} ** 24;
    var daily = [_]HourBucket{.{}} ** 7;

    // 90-minute active interval
    const now = std.time.timestamp();
    const start = startOfDay(now) + 10 * 3600; // 10:00 today
    const iv = db.Interval{ .start_time = start, .end_time = start + 5400, .afk = false };
    bucketInterval(&hourly, &daily, iv, startOfDay(now));

    // Total active seconds across all hourly buckets should equal 5400
    var total: i64 = 0;
    for (hourly) |b| total += b.active;
    try std.testing.expectEqual(@as(i64, 5400), total);
}

test "bucketInterval separates active and afk" {
    var hourly = [_]HourBucket{.{}} ** 24;
    var daily = [_]HourBucket{.{}} ** 7;

    const now = std.time.timestamp();
    const base = startOfDay(now) + 14 * 3600; // 14:00
    const active = db.Interval{ .start_time = base, .end_time = base + 1800, .afk = false };
    const afk = db.Interval{ .start_time = base + 1800, .end_time = base + 3600, .afk = true };
    bucketInterval(&hourly, &daily, active, startOfDay(now));
    bucketInterval(&hourly, &daily, afk, startOfDay(now));

    var total_active: i64 = 0;
    var total_afk: i64 = 0;
    for (hourly) |b| {
        total_active += b.active;
        total_afk += b.afk;
    }
    try std.testing.expectEqual(@as(i64, 1800), total_active);
    try std.testing.expectEqual(@as(i64, 1800), total_afk);
}

test "bucketInterval daily totals match" {
    var hourly = [_]HourBucket{.{}} ** 24;
    var daily = [_]HourBucket{.{}} ** 7;

    const now = std.time.timestamp();
    const day_start = startOfDay(now);
    const iv = db.Interval{ .start_time = day_start + 8 * 3600, .end_time = day_start + 17 * 3600, .afk = false };
    bucketInterval(&hourly, &daily, iv, day_start);

    // Daily bucket 0 (today) should have 9 hours
    try std.testing.expectEqual(@as(i64, 9 * 3600), daily[0].active);
}
