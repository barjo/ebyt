# EBYT — Every Byte You Track

[![CI](https://github.com/barjo/ebyt/actions/workflows/ci.yml/badge.svg)](https://github.com/barjo/ebyt/actions/workflows/ci.yml)

> "Every move you make, every byte you track..."

Minimal X11 activity tracker. Logs which window is focused, for how long, and when you're AFK. Data goes into SQLite. That's it.

For full-featured activity tracking with broader support, see [ActivityWatch](https://activitywatch.net/) or [arbtt](https://arbtt.nomeata.de/).
ebyt intentionally stays small, X11 only, SQLite only, no plugins, no config files.
Advanced reporting should query the database directly (`sqlite3`, scripts, whatever you prefer).

## Dependencies

- **Zig** >= 0.14.0
- **libX11** — active window detection (`WM_CLASS`, `_NET_WM_NAME`)
- **libXi** — XInput2 raw events for AFK detection
- **libsqlite3** — local database

That's the standard X11 libraries. SQLite is likely already installed on any desktop system.

## Install

On Arch (via AUR):

```sh
yay -S ebyt-bin   # prebuilt binary
yay -S ebyt       # build from source
```

Or grab the binary from the [releases page](https://github.com/barjo/ebyt/releases).

## Build

```sh
zig build
zig build -Doptimize=ReleaseSafe  # optimized binary
```

Binary goes to `zig-out/bin/ebyt`.

## Usage

```
ebyt daemon [--poll 5] [--afk-timeout 300]    # start daemon (foreground)
ebyt report [--today|--week|--since DATE]     # show time report
            [--detail] [--csv]
ebyt status                                   # current window + tracking uptime
```

### Daemon

Polls the active X11 window at a configurable interval (default 5s). Detects AFK after a configurable timeout (default 300s) using XInput2 raw input events. Shuts down gracefully on SIGINT/SIGTERM.

### Report

```
  Fri Apr 03, 2026

  firefox                   2h 15m  ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░  45%
  Alacritty                 1h 30m  ▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░  30%
  code                      0h 45m  ▓▓▓░░░░░░░░░░░░░░░░░░░░░  15%
  AFK                       0h 30m  ▓▓░░░░░░░░░░░░░░░░░░░░░░  10%

                                                            5h 00m
```

Report options:

- `--today` — show today's activity (default)
- `--week` — show this week's activity
- `--since YYYY-MM-DD` — show activity since a specific date
- `--detail` — show top window titles per app
- `--csv` — output as CSV (class, title, start time, duration)

## Systemd

A user service is included. The AUR packages install it automatically:

```sh
systemctl --user enable --now ebyt
```

For manual installs, the service expects the binary at `/usr/bin/ebyt`:

```sh
cp ebyt.service ~/.config/systemd/user/
```

## Database

SQLite, stored at `$XDG_STATE_HOME/ebyt/ebyt.db` (defaults to `~/.local/state/ebyt/ebyt.db`). One row per continuous activity on the same window — rows are extended on each poll if nothing changed, new row on window or AFK state change.

```sql
SELECT window_class, SUM(end_time - start_time) as seconds
FROM activities
WHERE afk = 0 AND start_time > unixepoch('now', '-7 days')
GROUP BY window_class
ORDER BY seconds DESC;
```

## Limitations

Window class and title are truncated to 256 bytes. Good enough ~(^_^)~

## Disclaimer

First Zig project, written with the help of an AI coding assistant. It works, but review accordingly.

## License

Apache-2.0
