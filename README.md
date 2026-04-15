# EBYT — Every Byte You Track

[![CI](https://github.com/barjo/ebyt/actions/workflows/ci.yml/badge.svg)](https://github.com/barjo/ebyt/actions/workflows/ci.yml)

> "Every move you make, every byte you track..."

Minimal X11 activity tracker. Logs which window is focused, for how long, and when you're AFK. Data goes into SQLite. That's it.

![demo](assets/demo.gif)

For full-featured activity tracking with broader support, see [ActivityWatch](https://activitywatch.net/) or [arbtt](https://arbtt.nomeata.de/).
ebyt intentionally stays small, X11 only, SQLite only, no plugins, no config files.
Use the built-in TUI for interactive browsing, or query the database directly (`sqlite3`, scripts, whatever you prefer).

## Dependencies

- **Zig** >= 0.15.0
- **libX11** — active window detection (`WM_CLASS`, `_NET_WM_NAME`)
- **libXi** — XInput2 raw events for AFK detection
- **libsqlite3** — local database
- **[zigzag](https://github.com/meszmate/zigzag)** — TUI framework (fetched automatically by `zig build`)

The system libraries (X11, Xi, sqlite3) are standard on most Linux desktops.

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
ebyt tui                                      # interactive dashboard
ebyt export [--today|--week|--since DATE]     # export as CSV
ebyt status                                   # current window + tracking uptime
```

### Daemon

Polls the active X11 window at a configurable interval (default 5s). Detects AFK after a configurable timeout (default 300s) using XInput2 raw input events. Shuts down gracefully on SIGINT/SIGTERM.

### TUI

Interactive terminal dashboard built with [zigzag](https://github.com/meszmate/zigzag). Day and week views with stacked active/AFK bar charts, per-app breakdowns with expandable window titles, and vim-style navigation.

### Export

CSV export for scripting and external tools:

```sh
ebyt export                       # today's activity
ebyt export --week                # this week
ebyt export --since 2026-01-01    # since a specific date
```

Output: `window_class,window_title,start_time,duration(s)`

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
