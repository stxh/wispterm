//! Decode `Shell_NotifyIcon` callback messages.
//!
//! With `NOTIFYICON_VERSION_4` the shell packs the event in `LOWORD(lParam)`
//! and the icon id in `HIWORD(lParam)`. `wParam` is the mouse coordinate, not
//! the icon id (that was the pre-v4 layout). The decoder is integer-only so
//! it can be unit-tested on every host. Ghostty's GTK notifications set
//! `app.present-surface` as the default action so a click presents the app;
//! this is the Windows equivalent of recognizing that click.

const std = @import("std");

pub const tray_callback_msg: u32 = 0x8000 + 0x4E; // WM_APP + 'N'
pub const tray_icon_id: u32 = 1;

const wm_user: u32 = 0x0400;
pub const nin_select: u32 = wm_user + 0;
pub const nin_keyselect: u32 = wm_user + 1;
pub const nin_balloon_user_click: u32 = wm_user + 5;
pub const wm_lbuttonup: u32 = 0x0202;

pub const Click = enum { balloon, icon };

/// `wparam`/`lparam` match the Win32 `WPARAM`/`LPARAM` integer widths.
pub fn decode(msg: u32, wparam: usize, lparam: isize) ?Click {
    if (msg != tray_callback_msg) return null;
    _ = wparam;
    const raw: u64 = @bitCast(@as(i64, lparam));
    const event: u32 = @as(u16, @truncate(raw));
    return switch (event) {
        nin_balloon_user_click => .balloon,
        nin_select, nin_keyselect, wm_lbuttonup => .icon,
        else => null,
    };
}

fn packLParam(lo: u16, hi: u16) isize {
    const packed_val: u32 = @as(u32, lo) | (@as(u32, hi) << 16);
    return @intCast(packed_val);
}

test "VERSION_4 balloon click is in LOWORD(lParam); wParam is coordinates" {
    const wparam: usize = 0x00C8_0064; // y=200, x=100 — never equals the icon id
    const lparam = packLParam(nin_balloon_user_click, tray_icon_id);
    try std.testing.expectEqual(Click.balloon, decode(tray_callback_msg, wparam, lparam).?);
    try std.testing.expect(wparam != tray_icon_id);
}

test "pre-v4 balloon click still decodes (event in lParam, icon id in wParam)" {
    try std.testing.expectEqual(
        Click.balloon,
        decode(tray_callback_msg, tray_icon_id, nin_balloon_user_click).?,
    );
}

test "tray icon select and left-click also count as activation" {
    try std.testing.expectEqual(
        Click.icon,
        decode(tray_callback_msg, 0, packLParam(nin_select, tray_icon_id)).?,
    );
    try std.testing.expectEqual(
        Click.icon,
        decode(tray_callback_msg, 0, packLParam(nin_keyselect, tray_icon_id)).?,
    );
    try std.testing.expectEqual(
        Click.icon,
        decode(tray_callback_msg, 0, packLParam(wm_lbuttonup, tray_icon_id)).?,
    );
}

test "unrelated messages and balloon timeout are ignored" {
    const nin_balloon_timeout: u32 = wm_user + 4;
    try std.testing.expectEqual(@as(?Click, null), decode(0x0010, 0, 0));
    try std.testing.expectEqual(
        @as(?Click, null),
        decode(tray_callback_msg, 0, packLParam(nin_balloon_timeout, tray_icon_id)),
    );
}

test "windows toast handler uses the VERSION_4 decoder, not wParam as icon id" {
    const source = @embedFile("notifications_windows.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "wParam == TRAY_ICON_ID") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "tray_callback.decode") != null);
}
