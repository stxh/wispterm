//! OSC 0/1/2 window-title and OSC 7 cwd scanner.
//!
//! Ghostty parses the *complete* OSC command number before dispatching
//! (`ghostty/src/terminal/osc.zig`: OSC 0/2 → `change_window_title`,
//! OSC 10–19 / 104 / 110–119 → color/palette). WispTerm used to treat the
//! first digit 0/1/2/7 as a title command, so multi-digit color sequences
//! such as OSC 10/11 (`#eeeeee`, `#fab283`) became the tab/window title.

const std = @import("std");

pub const Event = struct {
    /// 0/1/2 = window/icon title, 7 = OSC 7 cwd.
    code: u8,
    text: []const u8,
};

pub fn isTitleOrCwdOsc(code: u16) bool {
    return code == 0 or code == 1 or code == 2 or code == 7;
}

pub const Scanner = struct {
    const State = enum { ground, esc, osc_num, osc_payload };

    state: State = .ground,
    code: u16 = 0,
    buf: [512]u8 = undefined,
    buf_len: usize = 0,

    pub fn feed(
        self: *Scanner,
        data: []const u8,
        ctx: anytype,
        comptime on_event: fn (@TypeOf(ctx), Event) void,
    ) void {
        for (data) |byte| {
            if (self.step(byte)) |event| on_event(ctx, event);
        }
    }

    fn step(self: *Scanner, byte: u8) ?Event {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) self.state = .esc;
            },
            .esc => {
                if (byte == ']') {
                    self.state = .osc_num;
                    self.code = 0;
                } else {
                    self.state = .ground;
                }
            },
            .osc_num => {
                if (byte >= '0' and byte <= '9') {
                    const next: u32 = @as(u32, self.code) * 10 + (byte - '0');
                    if (next > 9999) {
                        self.state = .ground;
                    } else {
                        self.code = @intCast(next);
                    }
                } else if (byte == ';') {
                    if (isTitleOrCwdOsc(self.code)) {
                        self.buf_len = 0;
                        self.state = .osc_payload;
                    } else {
                        self.state = .ground;
                    }
                } else {
                    self.state = .ground;
                }
            },
            .osc_payload => {
                if (byte == 0x07) {
                    const event = self.payloadEvent();
                    self.state = .ground;
                    return event;
                } else if (byte == 0x1b) {
                    const event = self.payloadEvent();
                    self.state = .esc;
                    return event;
                } else if (self.buf_len < self.buf.len) {
                    self.buf[self.buf_len] = byte;
                    self.buf_len += 1;
                }
            },
        }
        return null;
    }

    fn payloadEvent(self: *const Scanner) Event {
        return .{
            .code = @intCast(self.code),
            .text = self.buf[0..self.buf_len],
        };
    }
};

const Collect = struct {
    title: [256]u8 = undefined,
    title_len: usize = 0,
    last_code: u8 = 255,
    events: usize = 0,

    fn onEvent(self: *Collect, event: Event) void {
        const n = @min(event.text.len, self.title.len);
        @memcpy(self.title[0..n], event.text[0..n]);
        self.title_len = n;
        self.last_code = event.code;
        self.events += 1;
    }

    fn text(self: *const Collect) []const u8 {
        return self.title[0..self.title_len];
    }
};

fn scan(data: []const u8) Collect {
    var scanner: Scanner = .{};
    var out: Collect = .{};
    scanner.feed(data, &out, Collect.onEvent);
    return out;
}

test "OSC 0/2 set the window title including Unicode" {
    const osc0 = scan("\x1b]0;Capabilities\x07");
    try std.testing.expectEqual(@as(u8, 0), osc0.last_code);
    try std.testing.expectEqualStrings("Capabilities", osc0.text());

    const osc2 = scan("\x1b]2;π - box\x07");
    try std.testing.expectEqual(@as(u8, 2), osc2.last_code);
    try std.testing.expectEqualStrings("π - box", osc2.text());
}

test "OSC 10/11 color sequences are not titles" {
    const fg = scan("\x1b]10;#eeeeee\x07");
    try std.testing.expectEqual(@as(usize, 0), fg.events);

    const bg = scan("\x1b]11;#fab283\x07");
    try std.testing.expectEqual(@as(usize, 0), bg.events);

    const query = scan("\x1b]11;?\x07");
    try std.testing.expectEqual(@as(usize, 0), query.events);

    const rgb = scan("\x1b]10;rgb:ee/ee/ee\x07");
    try std.testing.expectEqual(@as(usize, 0), rgb.events);
}

test "OSC 4/104 palette sequences are not titles" {
    try std.testing.expectEqual(@as(usize, 0), scan("\x1b]4;0;#eeeeee\x07").events);
    try std.testing.expectEqual(@as(usize, 0), scan("\x1b]104;0\x07").events);
}

test "a real OSC 0 title still wins after a color sequence" {
    var scanner: Scanner = .{};
    var out: Collect = .{};
    scanner.feed("\x1b]11;#eeeeee\x07\x1b]0;π - box\x07", &out, Collect.onEvent);
    try std.testing.expectEqual(@as(usize, 1), out.events);
    try std.testing.expectEqualStrings("π - box", out.text());
}

test "color OSC after a title does not overwrite it" {
    var scanner: Scanner = .{};
    var out: Collect = .{};
    scanner.feed("\x1b]0;grok\x07\x1b]11;#fab283\x07", &out, Collect.onEvent);
    try std.testing.expectEqual(@as(usize, 1), out.events);
    try std.testing.expectEqualStrings("grok", out.text());
}

test "title sequences split across reads keep state" {
    var scanner: Scanner = .{};
    var out: Collect = .{};
    scanner.feed("\x1b]0;hel", &out, Collect.onEvent);
    try std.testing.expectEqual(@as(usize, 0), out.events);
    scanner.feed("lo\x07", &out, Collect.onEvent);
    try std.testing.expectEqualStrings("hello", out.text());
}

test "ST-terminated OSC 2 is accepted" {
    const got = scan("\x1b]2;wispterm\x1b\\");
    try std.testing.expectEqual(@as(u8, 2), got.last_code);
    try std.testing.expectEqualStrings("wispterm", got.text());
}

test "OSC 7 is reported as cwd, not ignored" {
    const got = scan("\x1b]7;file://host/home/box\x07");
    try std.testing.expectEqual(@as(u8, 7), got.last_code);
    try std.testing.expectEqualStrings("file://host/home/box", got.text());
}

test "isTitleOrCwdOsc matches Ghostty's title/cwd numbers only" {
    try std.testing.expect(isTitleOrCwdOsc(0));
    try std.testing.expect(isTitleOrCwdOsc(1));
    try std.testing.expect(isTitleOrCwdOsc(2));
    try std.testing.expect(isTitleOrCwdOsc(7));
    try std.testing.expect(!isTitleOrCwdOsc(4));
    try std.testing.expect(!isTitleOrCwdOsc(10));
    try std.testing.expect(!isTitleOrCwdOsc(11));
    try std.testing.expect(!isTitleOrCwdOsc(12));
    try std.testing.expect(!isTitleOrCwdOsc(104));
    try std.testing.expect(!isTitleOrCwdOsc(777));
}
