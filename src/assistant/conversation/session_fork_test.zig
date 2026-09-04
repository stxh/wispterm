//! Session-level tests for the rewind-picker fork trigger (`f`). They live
//! outside session.zig to keep that file under the 10,000-line backstop;
//! struct fields are accessible cross-file, so the tests drive the same public
//! surface input.zig uses (handleChar / openRewindPicker) plus the fork
//! trigger hook AppWindow registers.

const std = @import("std");
const ai_chat = @import("session.zig");

const Session = ai_chat.Session;

const ForkHook = struct {
    var fired: bool = false;
    var target: ?*Session = null;
    var user_point: usize = 0;

    fn reset() void {
        fired = false;
        target = null;
        user_point = 0;
    }

    fn cb(session: *Session, n: usize) void {
        fired = true;
        target = session;
        user_point = n;
    }
};

fn freeMessages(session: *Session, a: std.mem.Allocator) void {
    for (session.messages.items) |msg| msg.deinit(a);
    session.messages.deinit(a);
}

test "rewind fork key fires the deferred fork trigger with the persisted user-point index" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    // A non-persisted user message sits between two persisted ones: the record
    // ordinal must skip it (records only carry persist_to_history messages).
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "scratch"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r2") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker(); // 3 rewind points; selection defaults to the newest ("second")
    try std.testing.expect(session.rewind_open);

    session.handleChar('f');

    try std.testing.expect(ForkHook.fired);
    try std.testing.expectEqual(&session, ForkHook.target.?);
    // Before "second" only "first" is persisted -> the fork keeps 1 user message.
    try std.testing.expectEqual(@as(usize, 1), ForkHook.user_point);
    try std.testing.expect(!session.rewind_open);
    // A fork never mutates the source session.
    try std.testing.expectEqual(@as(usize, 5), session.messages.items.len);
}

test "rewind fork key on the oldest rewind point yields user point zero" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker(); // selected = 1 (newest)
    session.moveRewindSelection(-1); // oldest point "one"
    session.handleChar('F'); // uppercase works too

    try std.testing.expect(ForkHook.fired);
    try std.testing.expectEqual(@as(usize, 0), ForkHook.user_point);
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);
}

test "rewind fork key is inert while a request is in flight" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.openRewindPicker();
    try std.testing.expect(session.rewind_open);
    session.request_inflight = true; // a request started after the picker opened

    session.handleChar('f');

    try std.testing.expect(!ForkHook.fired);
    try std.testing.expect(session.rewind_open); // picker stays up, like confirmRewind's idle gate
}

test "plain f without an open rewind picker still types into the composer" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer freeMessages(&session, a);

    ForkHook.reset();
    ai_chat.setForkAtRewindTrigger(ForkHook.cb);
    defer ai_chat.setForkAtRewindTrigger(null);

    session.handleChar('f');

    try std.testing.expect(!ForkHook.fired);
    try std.testing.expectEqualStrings("f", session.input());
}
