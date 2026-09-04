//! Pure formatting helpers for the "Send to Chat" feature: the terminal
//! selection (or a tail of recent output) is wrapped in a fenced Markdown code
//! block and attached to a Copilot session as a collapsed context card.
//!
//! Kept free of AppWindow/Surface dependencies so it runs in the fast suite.

const std = @import("std");

/// Hard cap for one context-card body, matching the AI History attach budget.
pub const max_body_bytes: usize = 48 * 1024;

/// Lines of recent terminal output used when there is no active selection.
pub const recent_output_lines: usize = 40;

/// Marker prepended when the body had to be truncated to fit `max_body_bytes`.
const truncation_marker = "[... truncated ...]\n";

/// Formatted card body. `text` is owned by the caller; free with `deinit`.
pub const Body = struct {
    text: []u8,
    truncated: bool,

    pub fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// The last `max_lines` lines of `text` (trailing newlines trimmed first).
/// Returns a slice of `text`; no allocation.
pub fn tailLines(text: []const u8, max_lines: usize) []const u8 {
    const trimmed = std.mem.trimRight(u8, text, "\n");
    if (max_lines == 0) return trimmed[0..0];
    var start: usize = trimmed.len;
    var newlines: usize = 0;
    while (start > 0) {
        if (trimmed[start - 1] == '\n') {
            newlines += 1;
            if (newlines >= max_lines) break;
        }
        start -= 1;
    }
    return trimmed[start..];
}

/// Wrap `content` in a fenced code block (``` fence, widened past any run of
/// backticks inside the content). When the result would exceed `max_bytes`,
/// the content is truncated from the head — keeping the newest tail, on a
/// UTF-8 boundary — and marked with `truncation_marker`.
pub fn allocFencedBody(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_bytes: usize,
) !Body {
    const trimmed = std.mem.trimRight(u8, content, "\n");

    var fence_buf: [16]u8 = undefined;
    const fence_len = @min(@max(longestBacktickRun(trimmed) + 1, 3), fence_buf.len);
    @memset(fence_buf[0..fence_len], '`');
    const fence = fence_buf[0..fence_len];

    // Layout: fence "\n" [marker] body "\n" fence
    const overhead = fence.len * 2 + 2;
    var body = trimmed;
    var truncated = false;
    if (overhead + trimmed.len > max_bytes) {
        truncated = true;
        const room = max_bytes -| (overhead + truncation_marker.len);
        body = trimmed[utf8SafeTailStart(trimmed, room)..];
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, fence);
    try out.append(allocator, '\n');
    if (truncated) try out.appendSlice(allocator, truncation_marker);
    try out.appendSlice(allocator, body);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, fence);
    return .{ .text = try out.toOwnedSlice(allocator), .truncated = truncated };
}

fn longestBacktickRun(text: []const u8) usize {
    var best: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        if (c == '`') {
            run += 1;
            if (run > best) best = run;
        } else {
            run = 0;
        }
    }
    return best;
}

/// Start index of the last `tail_len` bytes of `s`, advanced to a UTF-8
/// codepoint boundary so the slice never splits a multi-byte character.
fn utf8SafeTailStart(s: []const u8, tail_len: usize) usize {
    var start = s.len - @min(s.len, tail_len);
    while (start < s.len and (s[start] & 0xC0) == 0x80) {
        start += 1;
    }
    return start;
}

test "tailLines keeps the last N lines and trims trailing newlines" {
    try std.testing.expectEqualStrings("b\nc", tailLines("a\nb\nc", 2));
    try std.testing.expectEqualStrings("b\nc", tailLines("a\nb\nc\n\n", 2));
    try std.testing.expectEqualStrings("a\nb\nc", tailLines("a\nb\nc", 40));
    try std.testing.expectEqualStrings("c", tailLines("a\nb\nc", 1));
    try std.testing.expectEqualStrings("", tailLines("a\nb\nc", 0));
    try std.testing.expectEqualStrings("", tailLines("", 40));
}

test "allocFencedBody wraps content in a backtick fence" {
    const allocator = std.testing.allocator;
    var body = try allocFencedBody(allocator, "hello\nworld", max_body_bytes);
    defer body.deinit(allocator);
    try std.testing.expect(!body.truncated);
    try std.testing.expectEqualStrings("```\nhello\nworld\n```", body.text);
}

test "allocFencedBody widens the fence past inner backtick runs" {
    const allocator = std.testing.allocator;
    var body = try allocFencedBody(allocator, "code:\n```sh\nls\n```", max_body_bytes);
    defer body.deinit(allocator);
    try std.testing.expect(!body.truncated);
    try std.testing.expectEqualStrings("````\ncode:\n```sh\nls\n```\n````", body.text);
}

test "allocFencedBody truncates from the head on a UTF-8 boundary" {
    const allocator = std.testing.allocator;
    // 中 is 3 bytes in UTF-8; a naive cut could land inside it. Budget leaves
    // room for exactly "newest line" (11 bytes) after the marker + fence.
    const content = "old line with more text\n中中中\nnewest line";
    var body = try allocFencedBody(allocator, content, 41);
    defer body.deinit(allocator);
    try std.testing.expect(body.truncated);
    try std.testing.expect(body.text.len <= 41);
    try std.testing.expect(std.mem.startsWith(u8, body.text, "```\n" ++ truncation_marker));
    try std.testing.expect(std.mem.endsWith(u8, body.text, "newest line\n```"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(body.text));
}

test "allocFencedBody fits tiny budgets without underflow" {
    const allocator = std.testing.allocator;
    var body = try allocFencedBody(allocator, "some long content here", 12);
    defer body.deinit(allocator);
    try std.testing.expect(body.truncated);
    try std.testing.expect(body.text.len <= 12 + truncation_marker.len + 8);
    try std.testing.expect(std.unicode.utf8ValidateSlice(body.text));
}
