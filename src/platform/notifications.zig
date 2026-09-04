//! User-notification capability: signal terminal events to the user through
//! native OS facilities (alert sound and window attention requests).
//!
//! The bell and attention request are intentionally separate seams. Hosts
//! implement them very differently — Windows uses `MessageBeep` plus a taskbar
//! `FlashWindowEx`, macOS would use an alert sound plus
//! `NSApplication.requestUserAttention`, and Linux toolkits raise the window's
//! urgency hint or post a desktop notification through the session portal.

const std = @import("std");
const builtin = @import("builtin");
const platform_window = @import("window.zig");

pub const Backend = enum {
    windows,
    macos,
    linux,
    unsupported,
};

/// Cached desktop-notification authorization status. Mirrors the macOS
/// bridge contract: 0 = unavailable/not-determined, 1 = denied, 2 = authorized.
pub const NotifAuthStatus = enum(u8) { unavailable = 0, denied = 1, authorized = 2 };

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("notifications_windows.zig"),
    .macos => @import("notifications_macos.zig"),
    .linux => @import("notifications_linux.zig"),
    .unsupported => @import("notifications_unsupported.zig"),
};

/// True on platforms with a native desktop-notification backend (Windows,
/// macOS, and Linux).
pub const supports_desktop_notifications = switch (backendForOs(builtin.os.tag)) {
    .windows, .macos, .linux => true,
    else => false,
};

/// Native handle of the window a notification is associated with.
pub const NativeHandle = platform_window.NativeHandle;

/// Play the system alert sound for a terminal bell event.
pub fn bell() void {
    impl.bell();
}

/// Ask the OS to draw attention to the given window (taskbar flash, dock
/// bounce, or urgency hint), typically when the window is not focused. The
/// backend decides whether the window already has focus and skips redundant
/// attention requests.
pub fn requestAttention(handle: NativeHandle) void {
    impl.requestAttention(handle);
}

/// Remember the window a later toast click should present. No-op where the
/// backend has no click-to-focus path.
pub fn bindWindow(handle: NativeHandle) void {
    impl.bindWindow(handle);
}

/// Post a native desktop notification (Windows tray balloon / macOS toast /
/// Linux notify-send). No-op where unsupported.
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    impl.showDesktopNotification(title, body);
}

/// Consume a tray/toast click posted to the window's WndProc. Returns true
/// when the message was a notification click (the backend presents the
/// bound window). Always false on platforms without a tray callback.
pub fn handleCallback(
    msg: platform_window.MessageId,
    wparam: platform_window.WordParam,
    lparam: platform_window.LongParam,
) bool {
    return impl.handleCallback(msg, wparam, lparam);
}

/// Release any process-wide notification resources (Windows removes its tray
/// icon). Safe to call when nothing was shown; no-op on other platforms.
pub fn cleanup() void {
    impl.cleanup();
}

/// Current cached authorization status (synchronous, cheap).
pub fn notificationAuthStatus() NotifAuthStatus {
    return @enumFromInt(impl.notificationAuthStatus());
}

/// Ask the OS for notification permission (shows the system prompt once).
/// Safe to call repeatedly; the OS only prompts on the first undetermined call.
pub fn requestNotificationAuth() void {
    impl.requestNotificationAuth();
}

test "notifications selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.linux, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}

test "notifications exposes bell and attention API shape" {
    const bell_info = @typeInfo(@TypeOf(bell)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), bell_info.params.len);
    try std.testing.expect(bell_info.return_type.? == void);

    const attention_info = @typeInfo(@TypeOf(requestAttention)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), attention_info.params.len);
    try std.testing.expect(attention_info.params[0].type.? == NativeHandle);
    try std.testing.expect(attention_info.return_type.? == void);

    const show_info = @typeInfo(@TypeOf(showDesktopNotification)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), show_info.params.len);
    try std.testing.expect(show_info.return_type.? == void);

    const bind_info = @typeInfo(@TypeOf(bindWindow)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), bind_info.params.len);
    try std.testing.expect(bind_info.params[0].type.? == NativeHandle);
    try std.testing.expect(bind_info.return_type.? == void);

    const click_info = @typeInfo(@TypeOf(handleCallback)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), click_info.params.len);
    try std.testing.expect(click_info.return_type.? == bool);

    const status_info = @typeInfo(@TypeOf(notificationAuthStatus)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), status_info.params.len);
    try std.testing.expectEqual(NotifAuthStatus, status_info.return_type.?);
}
