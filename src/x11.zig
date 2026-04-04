const std = @import("std");
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/extensions/XInput2.h");
});

/// Reimplementation of XISetMask C macro: sets bit `event` in `mask`.
fn xiSetMask(mask: []u8, event: c_int) void {
    const e: u32 = @intCast(event);
    const byte_idx = e >> 3;
    const bit_idx: u3 = @intCast(e & 0x7);
    if (byte_idx < mask.len) {
        mask[byte_idx] |= @as(u8, 1) << bit_idx;
    }
}

pub const WindowInfo = struct {
    class: []const u8,
    title: []const u8,
};

pub const X11 = struct {
    display: *c.Display,
    root: c.Window,
    net_active_window: c.Atom,
    net_wm_name: c.Atom,
    utf8_string: c.Atom,
    xi_opcode: c_int,

    // Buffers owned by X11 — freed on next call or deinit
    class_buf: ?[*]u8 = null,
    title_buf: ?[*]u8 = null,

    pub fn init() !X11 {
        const display = c.XOpenDisplay(null) orelse return error.NoDisplay;
        const root = c.DefaultRootWindow(display);

        const net_active_window = c.XInternAtom(display, "_NET_ACTIVE_WINDOW", 0);
        const net_wm_name = c.XInternAtom(display, "_NET_WM_NAME", 0);
        const utf8_string = c.XInternAtom(display, "UTF8_STRING", 0);

        // Check for XInput2
        var xi_opcode: c_int = 0;
        var event: c_int = 0;
        var err: c_int = 0;
        if (c.XQueryExtension(display, "XInputExtension", &xi_opcode, &event, &err) == 0) {
            return error.NoXInput2;
        }

        // Select raw input events on root window
        var mask: [1]c.XIEventMask = undefined;
        var mask_bits = [1]u8{0} ** 4;
        xiSetMask(&mask_bits, c.XI_RawMotion);
        xiSetMask(&mask_bits, c.XI_RawKeyPress);
        xiSetMask(&mask_bits, c.XI_RawButtonPress);

        mask[0] = .{
            .deviceid = c.XIAllMasterDevices,
            .mask_len = mask_bits.len,
            .mask = &mask_bits,
        };

        _ = c.XISelectEvents(display, root, &mask, 1);
        _ = c.XFlush(display);

        return X11{
            .display = display,
            .root = root,
            .net_active_window = net_active_window,
            .net_wm_name = net_wm_name,
            .utf8_string = utf8_string,
            .xi_opcode = xi_opcode,
        };
    }

    pub fn deinit(self: *X11) void {
        if (self.class_buf) |p| _ = c.XFree(p);
        if (self.title_buf) |p| _ = c.XFree(p);
        _ = c.XCloseDisplay(self.display);
    }

    /// Get the currently focused window's class and title.
    /// Returns null if no window is focused or info can't be read.
    pub fn getActiveWindow(self: *X11) ?WindowInfo {
        const window = self.getActiveWindowId() orelse return null;

        const class = self.getWindowClass(window) orelse "unknown";
        const title = self.getWindowTitle(window) orelse "";

        return WindowInfo{
            .class = class,
            .title = title,
        };
    }

    fn getActiveWindowId(self: *X11) ?c.Window {
        var actual_type: c.Atom = undefined;
        var actual_format: c_int = undefined;
        var n_items: c_ulong = undefined;
        var bytes_after: c_ulong = undefined;
        var prop: ?[*]u8 = null;

        const status = c.XGetWindowProperty(
            self.display,
            self.root,
            self.net_active_window,
            0,
            1,
            0,
            c.XA_WINDOW,
            &actual_type,
            &actual_format,
            &n_items,
            &bytes_after,
            &prop,
        );

        if (status != 0 or n_items == 0) {
            if (prop) |p| _ = c.XFree(p);
            return null;
        }

        if (prop) |p| {
            defer _ = c.XFree(p);
            const window = @as(*const c.Window, @ptrCast(@alignCast(p))).*;
            if (window == 0) return null;
            return window;
        }
        return null;
    }

    fn getWindowClass(self: *X11, window: c.Window) ?[]const u8 {
        var class_hint: c.XClassHint = .{ .res_name = null, .res_class = null };
        if (c.XGetClassHint(self.display, window, &class_hint) == 0) {
            return null;
        }

        // Free previous name, keep class
        if (class_hint.res_name) |name| _ = c.XFree(name);

        if (self.class_buf) |prev| _ = c.XFree(prev);

        if (class_hint.res_class) |cls| {
            self.class_buf = cls;
            const len = std.mem.len(cls);
            return cls[0..len];
        }
        return null;
    }

    fn getWindowTitle(self: *X11, window: c.Window) ?[]const u8 {
        var actual_type: c.Atom = undefined;
        var actual_format: c_int = undefined;
        var n_items: c_ulong = undefined;
        var bytes_after: c_ulong = undefined;
        var prop: ?[*]u8 = null;

        // Try _NET_WM_NAME (UTF-8) first
        var status = c.XGetWindowProperty(
            self.display,
            window,
            self.net_wm_name,
            0,
            256,
            0,
            self.utf8_string,
            &actual_type,
            &actual_format,
            &n_items,
            &bytes_after,
            &prop,
        );

        if (status != 0 or n_items == 0) {
            if (prop) |p| _ = c.XFree(p);

            // Fallback to WM_NAME
            prop = null;
            status = c.XGetWindowProperty(
                self.display,
                window,
                c.XA_WM_NAME,
                0,
                256,
                0,
                c.XA_STRING,
                &actual_type,
                &actual_format,
                &n_items,
                &bytes_after,
                &prop,
            );

            if (status != 0 or n_items == 0) {
                if (prop) |p| _ = c.XFree(p);
                return null;
            }
        }

        if (self.title_buf) |prev| _ = c.XFree(prev);

        if (prop) |p| {
            self.title_buf = p;
            return p[0..n_items];
        }
        return null;
    }

    /// Drain all pending X events. Returns true if any input event was received
    /// (meaning user is active).
    pub fn drainEvents(self: *X11) bool {
        var had_input = false;

        while (c.XPending(self.display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &event);

            // XInput2 events come as GenericEvent
            if (event.type == c.GenericEvent and
                event.xcookie.extension == self.xi_opcode)
            {
                if (c.XGetEventData(self.display, &event.xcookie) != 0) {
                    defer c.XFreeEventData(self.display, &event.xcookie);

                    const evtype = event.xcookie.evtype;
                    if (evtype == c.XI_RawMotion or
                        evtype == c.XI_RawKeyPress or
                        evtype == c.XI_RawButtonPress)
                    {
                        had_input = true;
                    }
                }
            }
        }

        return had_input;
    }
};

// --- tests ---

test "xiSetMask sets correct bits" {
    var mask = [_]u8{0} ** 4;
    xiSetMask(&mask, 0);
    try std.testing.expectEqual(@as(u8, 0x01), mask[0]);

    mask = [_]u8{0} ** 4;
    xiSetMask(&mask, 9);
    try std.testing.expectEqual(@as(u8, 0x02), mask[1]);
}

test "xiSetMask ignores out-of-range events" {
    var mask = [_]u8{0} ** 4;
    xiSetMask(&mask, 32);
    try std.testing.expectEqual([_]u8{0} ** 4, mask);
}
