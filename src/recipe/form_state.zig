//! Pure state for the "Save Workspace Recipe" naming form: a single-line text
//! buffer plus row focus and visibility. No I/O, no drawing — rendering lives
//! in renderer/overlays.zig, persistence in store.zig, so this stays
//! unit-tested in the fast suite (same pattern as overlays/quick_ai_config.zig).
const std = @import("std");

pub const NAME_MAX: usize = 64;

// Form rows: 0 = recipe name field, 1 = Save.
pub const ROW_NAME: usize = 0;
pub const ROW_SAVE: usize = 1;
pub const ROW_COUNT: usize = 2;

pub const State = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    focus: usize = ROW_NAME,
    visible: bool = false,

    pub fn reset(self: *State) void {
        self.name_len = 0;
        self.focus = ROW_NAME;
    }

    pub fn show(self: *State) void {
        self.reset();
        self.visible = true;
    }

    pub fn hide(self: *State) void {
        self.visible = false;
        self.reset();
    }

    pub fn name(self: *const State) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn append(self: *State, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.name_len >= NAME_MAX) return; // truncate, no overflow
            self.name_buf[self.name_len] = b;
            self.name_len += 1;
        }
    }

    pub fn backspace(self: *State) void {
        if (self.name_len == 0) return;
        var n = self.name_len - 1;
        while (n > 0 and (self.name_buf[n] & 0xC0) == 0x80) : (n -= 1) {} // back one UTF-8 codepoint
        self.name_len = n;
    }

    pub fn focusNextRow(self: *State) void {
        if (self.focus < ROW_COUNT - 1) self.focus += 1;
    }

    pub fn focusPrevRow(self: *State) void {
        if (self.focus > 0) self.focus -= 1;
    }
};

test "State: show/hide toggles visibility and resets the buffer" {
    var s = State{};
    s.append("work");
    s.show();
    try std.testing.expect(s.visible);
    try std.testing.expectEqualStrings("", s.name());
    try std.testing.expectEqual(ROW_NAME, s.focus);
    s.append("dev setup");
    s.hide();
    try std.testing.expect(!s.visible);
    try std.testing.expectEqualStrings("", s.name());
}

test "State: append, name, backspace" {
    var s = State{};
    s.append("work");
    try std.testing.expectEqualStrings("work", s.name());
    s.backspace();
    try std.testing.expectEqualStrings("wor", s.name());
}

test "State: append truncates at NAME_MAX without overflow" {
    var s = State{};
    const big = "x" ** (NAME_MAX + 40);
    s.append(big);
    try std.testing.expectEqual(NAME_MAX, s.name().len);
}

test "State: backspace drops a whole multibyte codepoint" {
    var s = State{};
    s.append("a\u{4f60}"); // "a你"
    s.backspace();
    try std.testing.expectEqualStrings("a", s.name());
}

test "State: focus navigation clamps within rows" {
    var s = State{};
    s.focusPrevRow();
    try std.testing.expectEqual(ROW_NAME, s.focus);
    s.focusNextRow();
    try std.testing.expectEqual(ROW_SAVE, s.focus);
    s.focusNextRow();
    try std.testing.expectEqual(ROW_SAVE, s.focus);
}
