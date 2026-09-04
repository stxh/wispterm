//! Fork Session 的纯逻辑：把一份会话历史记录在某个 user 消息点截断，并生成
//! fork 会话的派生 id / 标题。会话层（session.zig）负责在锁内算出截断点，
//! 应用层（AppWindow.zig）负责取记录、换 id、入库和打开新会话；本模块只
//! 处理 record 本身，保持平台无关，进 fast suite。

const std = @import("std");
const agent_history = @import("../../agent/history.zig");

/// Fork 会话 id：`{base_id}-fork-{ms}-{counter}`，沿袭 model-switch
/// checkpoint 的派生 id 惯例（session.zig captureModelSwitchCheckpointLocked）。
pub fn allocForkSessionId(allocator: std.mem.Allocator, base_id: []const u8, ms: i64, counter: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-fork-{d}-{d}", .{ base_id, ms, counter });
}

/// Fork 会话标题：`{title} (fork)`。
pub fn allocForkTitle(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} (fork)", .{title});
}

/// 把 record 截断到第 user_point_index 条（0-based）user 消息之前：前
/// user_point_index 条 user 消息以及截断点之前的所有消息保留，第
/// user_point_index 条 user 消息及其后的消息全部释放。user_point_index
/// 大于等于 user 消息总数时不截断（分叉点 = 会话末尾）。OOM 时保持
/// record 不变（截断只是内存内重排，失败代价是 fork 带上全文，可接受）。
pub fn truncateRecordAtUserPoint(allocator: std.mem.Allocator, record: *agent_history.SessionRecord, user_point_index: usize) void {
    var seen: usize = 0;
    var cut: usize = record.messages.len;
    for (record.messages, 0..) |msg, i| {
        if (msg.role != .user) continue;
        if (seen == user_point_index) {
            cut = i;
            break;
        }
        seen += 1;
    }
    if (cut == record.messages.len) return;

    // 不能就地 reslice：freeOwnedRecord 之后会用同一 allocator free 整个
    // messages 切片，长度必须和分配时一致，所以把前 cut 条搬到一个刚好
    // cut 长的新切片，再释放被截掉的条目和旧切片。
    const kept = allocator.alloc(agent_history.MessageRecord, cut) catch return;
    @memcpy(kept, record.messages[0..cut]);
    for (record.messages[cut..]) |*msg| agent_history.freeOwnedMessage(allocator, msg);
    allocator.free(record.messages);
    record.messages = kept;
}

fn cloneTestRecord(allocator: std.mem.Allocator, messages: []const agent_history.MessageRecord) !agent_history.SessionRecord {
    return agent_history.cloneRecord(allocator, .{
        .session_id = "s1",
        .title = "Chat",
        .base_url = "https://api.example.com",
        .api_key = "k",
        .model = "m",
        .system_prompt = "p",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = messages,
    });
}

test "fork: truncate at a middle user point keeps the prefix before it" {
    const a = std.testing.allocator;
    var record = try cloneTestRecord(a, &.{
        .{ .role = .user, .content = "u0" },
        .{ .role = .assistant, .content = "a0" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .user, .content = "u2" },
        .{ .role = .assistant, .content = "a2" },
    });
    defer agent_history.freeOwnedRecord(a, &record);

    truncateRecordAtUserPoint(a, &record, 1);

    try std.testing.expectEqual(@as(usize, 2), record.messages.len);
    try std.testing.expectEqualStrings("u0", record.messages[0].content);
    try std.testing.expectEqualStrings("a0", record.messages[1].content);
}

test "fork: truncate at or past the last user point keeps everything" {
    const a = std.testing.allocator;
    var record = try cloneTestRecord(a, &.{
        .{ .role = .user, .content = "u0" },
        .{ .role = .assistant, .content = "a0" },
        .{ .role = .user, .content = "u1" },
    });
    defer agent_history.freeOwnedRecord(a, &record);

    truncateRecordAtUserPoint(a, &record, 2); // == user 消息总数：末尾
    try std.testing.expectEqual(@as(usize, 3), record.messages.len);

    truncateRecordAtUserPoint(a, &record, 99); // 越界同样不截断
    try std.testing.expectEqual(@as(usize, 3), record.messages.len);
}

test "fork: truncate at user point zero keeps only the pre-first-user prefix" {
    const a = std.testing.allocator;
    var record = try cloneTestRecord(a, &.{
        .{ .role = .tool, .content = "preload", .tool_name = "skill_info" },
        .{ .role = .user, .content = "u0" },
        .{ .role = .assistant, .content = "a0" },
    });
    defer agent_history.freeOwnedRecord(a, &record);

    truncateRecordAtUserPoint(a, &record, 0);

    try std.testing.expectEqual(@as(usize, 1), record.messages.len);
    try std.testing.expectEqual(agent_history.MessageRole.tool, record.messages[0].role);
    try std.testing.expectEqualStrings("preload", record.messages[0].content);
}

test "fork: truncate at user point zero with no prefix yields an empty record" {
    const a = std.testing.allocator;
    var record = try cloneTestRecord(a, &.{
        .{ .role = .user, .content = "u0" },
        .{ .role = .assistant, .content = "a0" },
    });
    defer agent_history.freeOwnedRecord(a, &record);

    truncateRecordAtUserPoint(a, &record, 0);

    try std.testing.expectEqual(@as(usize, 0), record.messages.len);
}

test "fork: truncate on an empty record is a no-op" {
    const a = std.testing.allocator;
    var record = try cloneTestRecord(a, &.{});
    defer agent_history.freeOwnedRecord(a, &record);

    truncateRecordAtUserPoint(a, &record, 0);
    try std.testing.expectEqual(@as(usize, 0), record.messages.len);
}

test "fork: derived id and title follow the checkpoint naming convention" {
    const a = std.testing.allocator;
    const id = try allocForkSessionId(a, "session-1-2", 3000, 7);
    defer a.free(id);
    try std.testing.expectEqualStrings("session-1-2-fork-3000-7", id);

    const title = try allocForkTitle(a, "Fix the bug");
    defer a.free(title);
    try std.testing.expectEqualStrings("Fix the bug (fork)", title);
}
