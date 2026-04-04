const std = @import("std");
const daemon = @import("daemon.zig");
const report = @import("report.zig");

const usage =
    \\Usage: ebyt <command> [options]
    \\
    \\Commands:
    \\  daemon    Start the activity tracker daemon
    \\  report    Show activity report
    \\  status    Show current tracking status
    \\
    \\Daemon options:
    \\  --poll <seconds>         Poll interval (default: 5)
    \\  --afk-timeout <seconds>  AFK threshold (default: 300)
    \\
    \\Report options:
    \\  --today                  Show today's activity (default)
    \\  --week                   Show this week's activity
    \\  --since <YYYY-MM-DD>     Show activity since date
    \\  --detail                 Show top window titles per app
    \\  --csv                    Output as CSV
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "daemon")) {
        var poll_interval: u32 = 5;
        var afk_timeout: u32 = 300;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--poll") and i + 1 < args.len) {
                i += 1;
                poll_interval = std.fmt.parseInt(u32, args[i], 10) catch {
                    try std.io.getStdErr().writeAll("Error: invalid --poll value\n");
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, args[i], "--afk-timeout") and i + 1 < args.len) {
                i += 1;
                afk_timeout = std.fmt.parseInt(u32, args[i], 10) catch {
                    try std.io.getStdErr().writeAll("Error: invalid --afk-timeout value\n");
                    std.process.exit(1);
                };
            } else {
                try std.io.getStdErr().writeAll(usage);
                std.process.exit(1);
            }
        }

        try daemon.run(allocator, poll_interval, afk_timeout);
    } else if (std.mem.eql(u8, command, "report")) {
        var mode: report.ReportMode = .today;
        var format: report.OutputFormat = .summary;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--today")) {
                mode = .today;
            } else if (std.mem.eql(u8, args[i], "--week")) {
                mode = .week;
            } else if (std.mem.eql(u8, args[i], "--since") and i + 1 < args.len) {
                i += 1;
                mode = .{ .since = args[i] };
            } else if (std.mem.eql(u8, args[i], "--detail")) {
                format = .detail;
            } else if (std.mem.eql(u8, args[i], "--csv")) {
                format = .csv;
            } else {
                try std.io.getStdErr().writeAll(usage);
                std.process.exit(1);
            }
        }

        try report.show(allocator, mode, format);
    } else if (std.mem.eql(u8, command, "status")) {
        try report.status(allocator);
    } else {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(1);
    }
}
