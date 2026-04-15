const std = @import("std");
const daemon = @import("daemon.zig");
const exp = @import("export.zig");
const tui = @import("tui.zig");

const usage =
    \\Usage: ebyt <command> [options]
    \\
    \\Commands:
    \\  daemon    Start the activity tracker daemon
    \\  tui       Interactive TUI dashboard
    \\  export    Export activity as CSV
    \\  status    Show current tracking status
    \\
    \\Daemon options:
    \\  --poll <seconds>         Poll interval (default: 5)
    \\  --afk-timeout <seconds>  AFK threshold (default: 300)
    \\
    \\Export options:
    \\  --today                  Export today's activity (default)
    \\  --week                   Export this week's activity
    \\  --since <YYYY-MM-DD>     Export activity since date
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll(usage);
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
                    try std.fs.File.stderr().writeAll("Error: invalid --poll value\n");
                    std.process.exit(1);
                };
            } else if (std.mem.eql(u8, args[i], "--afk-timeout") and i + 1 < args.len) {
                i += 1;
                afk_timeout = std.fmt.parseInt(u32, args[i], 10) catch {
                    try std.fs.File.stderr().writeAll("Error: invalid --afk-timeout value\n");
                    std.process.exit(1);
                };
            } else {
                try std.fs.File.stderr().writeAll(usage);
                std.process.exit(1);
            }
        }

        daemon.run(allocator, poll_interval, afk_timeout) catch |err| {
            fatal("daemon failed: {}", .{err});
        };
    } else if (std.mem.eql(u8, command, "export")) {
        var mode: exp.ExportMode = .today;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--today")) {
                mode = .today;
            } else if (std.mem.eql(u8, args[i], "--week")) {
                mode = .week;
            } else if (std.mem.eql(u8, args[i], "--since") and i + 1 < args.len) {
                i += 1;
                mode = .{ .since = args[i] };
            } else {
                try std.fs.File.stderr().writeAll(usage);
                std.process.exit(1);
            }
        }

        exp.exportCsv(allocator, mode) catch |err| {
            fatal("export failed: {}", .{err});
        };
    } else if (std.mem.eql(u8, command, "tui")) {
        tui.run(allocator) catch |err| {
            fatal("tui failed: {}", .{err});
        };
    } else if (std.mem.eql(u8, command, "status")) {
        exp.status(allocator) catch |err| {
            fatal("status failed: {}", .{err});
        };
    } else {
        try std.fs.File.stderr().writeAll(usage);
        std.process.exit(1);
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().writeAll("error: ") catch {};
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.writeAll("\n") catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}
