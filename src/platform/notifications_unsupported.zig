//! Notification backend for platforms without a native host yet: no-ops until
//! a port wires up the platform's alert sound and window-attention APIs.

const platform_window = @import("window.zig");

pub fn bell() void {}

pub fn bindWindow(handle: platform_window.NativeHandle) void {
    _ = handle;
}

pub fn requestAttention(handle: platform_window.NativeHandle) void {
    _ = handle;
}

pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    _ = title;
    _ = body;
}

pub fn notificationAuthStatus() u8 {
    return 0; // unavailable
}

pub fn requestNotificationAuth() void {}

pub fn handleCallback(
    msg: platform_window.MessageId,
    wparam: platform_window.WordParam,
    lparam: platform_window.LongParam,
) bool {
    _ = msg;
    _ = wparam;
    _ = lparam;
    return false;
}

pub fn cleanup() void {}
