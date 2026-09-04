//! OpenCode provider. Unlike the file-based providers, OpenCode storage is a
//! single SQLite database, so scanning and transcripts go through the CLI:
//! `opencode session list --format json` yields an array of
//! `{id, title, created, updated, projectId, directory}` (epoch milliseconds),
//! and `opencode export <sessionID>` yields `{info, messages: [{info, parts}]}`.
//! Everything here is fail-soft: missing fields fall back to defaults and
//! malformed input produces an empty result instead of an error (only OOM
//! propagates), so a schema drift degrades the list instead of failing the scan.

const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{OutOfMemory};

/// Parse the `opencode session list --format json` output into session rows.
/// Entries without an `id` are skipped (the id is required for export/resume);
/// a missing title falls back to the empty string. `source_path` carries the
/// session id: the transcript loader turns it back into `opencode export <id>`.
pub fn parseSessionList(allocator: std.mem.Allocator, json_bytes: []const u8) ParseError![]types.SessionMeta {
    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) return try allocator.alloc(types.SessionMeta, 0);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try allocator.alloc(types.SessionMeta, 0),
    };
    defer parsed.deinit();
    if (parsed.value != .array) return try allocator.alloc(types.SessionMeta, 0);

    var metas: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
    errdefer {
        for (metas.items) |meta| freeMetadata(allocator, meta);
        metas.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = objectString(obj, "id") orelse continue;
        if (id.len == 0) continue;

        var meta = try initMetadata(allocator, id);
        errdefer freeMetadata(allocator, meta);
        if (objectString(obj, "title")) |title| try replaceOwned(allocator, &meta.title, title);
        if (objectString(obj, "directory")) |directory| try replaceOwned(allocator, &meta.project_dir, directory);
        const created_ms = objectInt(obj, "created");
        const updated_ms = objectInt(obj, "updated");
        meta.created_at_ms = if (created_ms > 0) created_ms else updated_ms;
        meta.last_active_at_ms = @max(created_ms, updated_ms);

        try metas.append(allocator, meta);
    }

    return try metas.toOwnedSlice(allocator);
}

/// Parse the `opencode export <sessionID>` output into transcript messages.
/// Text parts become normal user/assistant messages; tool parts become a
/// tool_call (tool name) plus a tool_result (state.output); reasoning and
/// step marker parts are skipped.
pub fn parseTranscript(allocator: std.mem.Allocator, json_bytes: []const u8) ParseError![]types.TranscriptMessage {
    var messages: std.ArrayListUnmanaged(types.TranscriptMessage) = .empty;
    errdefer {
        freeTranscriptList(allocator, messages.items);
        messages.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) return try messages.toOwnedSlice(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try messages.toOwnedSlice(allocator),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try messages.toOwnedSlice(allocator);

    const root = parsed.value.object;
    const list = root.get("messages") orelse return try messages.toOwnedSlice(allocator);
    if (list != .array) return try messages.toOwnedSlice(allocator);

    for (list.array.items) |item| {
        if (item != .object) continue;
        const message = item.object;
        const info = objectObject(message, "info") orelse continue;
        const role = messageRole(objectString(info, "role") orelse "") orelse continue;
        const time = objectObject(info, "time");
        const timestamp_ms = if (time) |t| objectInt(t, "created") else 0;

        const parts = message.get("parts") orelse continue;
        if (parts != .array) continue;
        for (parts.array.items) |part_value| {
            if (part_value != .object) continue;
            const part = part_value.object;
            const part_type = objectString(part, "type") orelse continue;
            if (std.mem.eql(u8, part_type, "text")) {
                const text = objectString(part, "text") orelse continue;
                try appendMessage(allocator, &messages, role, .normal, text, timestamp_ms);
            } else if (std.mem.eql(u8, part_type, "tool")) {
                if (objectString(part, "tool")) |name| {
                    try appendMessage(allocator, &messages, .assistant, .tool_call, name, timestamp_ms);
                }
                if (objectObject(part, "state")) |state| {
                    if (objectString(state, "output")) |output| {
                        try appendMessage(allocator, &messages, .tool, .tool_result, output, timestamp_ms);
                    }
                }
            }
        }
    }

    return try messages.toOwnedSlice(allocator);
}

/// Frees metadata rows returned by parseSessionList.
pub fn freeMetadata(allocator: std.mem.Allocator, meta: types.SessionMeta) void {
    allocator.free(meta.session_id);
    allocator.free(meta.title);
    allocator.free(meta.project_dir);
    allocator.free(meta.source_path);
}

pub fn freeTranscript(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    freeTranscriptList(allocator, messages);
    allocator.free(messages);
}

fn initMetadata(allocator: std.mem.Allocator, session_id: []const u8) ParseError!types.SessionMeta {
    const session_id_owned = try allocator.dupe(u8, session_id);
    errdefer allocator.free(session_id_owned);
    const title = try allocator.dupe(u8, "");
    errdefer allocator.free(title);
    const project_dir = try allocator.dupe(u8, "");
    errdefer allocator.free(project_dir);
    const source_path_owned = try allocator.dupe(u8, session_id);

    return .{
        .provider = .opencode,
        .session_id = session_id_owned,
        .title = title,
        .project_dir = project_dir,
        .source_path = source_path_owned,
        .resume_kind = .opencode_resume,
    };
}

fn appendMessage(
    allocator: std.mem.Allocator,
    messages: *std.ArrayListUnmanaged(types.TranscriptMessage),
    role: types.MessageRole,
    kind: types.MessageKind,
    content: []const u8,
    timestamp_ms: i64,
) ParseError!void {
    if (content.len == 0) return;
    const owned = try allocator.dupe(u8, content);
    errdefer allocator.free(owned);
    try messages.append(allocator, .{ .role = role, .kind = kind, .content = owned, .timestamp_ms = timestamp_ms });
}

fn freeTranscriptList(allocator: std.mem.Allocator, messages: []types.TranscriptMessage) void {
    for (messages) |message| allocator.free(message.content);
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = obj.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn objectInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const value = obj.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| number,
        else => 0,
    };
}

fn messageRole(role: []const u8) ?types.MessageRole {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    return null;
}

fn replaceOwned(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) ParseError!void {
    const owned = try allocator.dupe(u8, value);
    allocator.free(field.*);
    field.* = owned;
}

test "ai_history_provider_opencode: parses session list entries" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "id": "ses_03282e836ffeRuTJVdTjunUnUs",
        \\    "title": "Fix the renderer",
        \\    "updated": 1785858960287,
        \\    "created": 1785858955210,
        \\    "projectId": "global",
        \\    "directory": "/home/me/project"
        \\  },
        \\  {
        \\    "id": "ses_second",
        \\    "title": "Second",
        \\    "created": 1785858950000,
        \\    "updated": 1785858959000,
        \\    "directory": "/home/me/other"
        \\  }
        \\]
    ;

    const metas = try parseSessionList(allocator, json);
    defer {
        for (metas) |meta| freeMetadata(allocator, meta);
        allocator.free(metas);
    }

    try std.testing.expectEqual(@as(usize, 2), metas.len);
    try std.testing.expectEqual(types.ProviderId.opencode, metas[0].provider);
    try std.testing.expectEqualStrings("ses_03282e836ffeRuTJVdTjunUnUs", metas[0].session_id);
    try std.testing.expectEqualStrings("ses_03282e836ffeRuTJVdTjunUnUs", metas[0].source_path);
    try std.testing.expectEqualStrings("Fix the renderer", metas[0].title);
    try std.testing.expectEqualStrings("/home/me/project", metas[0].project_dir);
    try std.testing.expectEqual(types.ResumeKind.opencode_resume, metas[0].resume_kind);
    try std.testing.expectEqual(@as(i64, 1785858955210), metas[0].created_at_ms);
    try std.testing.expectEqual(@as(i64, 1785858960287), metas[0].last_active_at_ms);
}

test "ai_history_provider_opencode: session list is fail-soft on missing fields" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"title": "no id is skipped", "created": 1},
        \\  {"id": "ses_bare"},
        \\  {"id": "ses_partial", "title": 42, "created": "not-a-number", "updated": 1785858960287},
        \\  "not an object"
        \\]
    ;

    const metas = try parseSessionList(allocator, json);
    defer {
        for (metas) |meta| freeMetadata(allocator, meta);
        allocator.free(metas);
    }

    try std.testing.expectEqual(@as(usize, 2), metas.len);
    try std.testing.expectEqualStrings("ses_bare", metas[0].session_id);
    try std.testing.expectEqualStrings("", metas[0].title);
    try std.testing.expectEqualStrings("", metas[0].project_dir);
    try std.testing.expectEqual(@as(i64, 0), metas[0].created_at_ms);
    try std.testing.expectEqual(@as(i64, 0), metas[0].last_active_at_ms);
    try std.testing.expectEqualStrings("ses_partial", metas[1].session_id);
    try std.testing.expectEqualStrings("", metas[1].title);
    try std.testing.expectEqual(@as(i64, 1785858960287), metas[1].created_at_ms);
    try std.testing.expectEqual(@as(i64, 1785858960287), metas[1].last_active_at_ms);
}

test "ai_history_provider_opencode: empty and malformed session lists yield no rows" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "  \n", "[]", "{}", "not json at all", "[{" }) |json| {
        const metas = try parseSessionList(allocator, json);
        defer allocator.free(metas);
        try std.testing.expectEqual(@as(usize, 0), metas.len);
    }
}

test "ai_history_provider_opencode: parses exported transcript parts" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "info": {"id": "ses_abc", "title": "Demo"},
        \\  "messages": [
        \\    {
        \\      "info": {"role": "user", "time": {"created": 1785858955271}},
        \\      "parts": [{"type": "text", "text": "inspect the repo"}]
        \\    },
        \\    {
        \\      "info": {"role": "assistant", "time": {"created": 1785858955278}},
        \\      "parts": [
        \\        {"type": "step-start"},
        \\        {"type": "reasoning", "text": "hidden chain of thought"},
        \\        {"type": "tool", "tool": "Read", "state": {"status": "completed", "output": "file contents"}},
        \\        {"type": "text", "text": "done"},
        \\        {"type": "step-finish"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    const messages = try parseTranscript(allocator, json);
    defer freeTranscript(allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqual(types.MessageKind.normal, messages[0].kind);
    try std.testing.expectEqualStrings("inspect the repo", messages[0].content);
    try std.testing.expectEqual(@as(i64, 1785858955271), messages[0].timestamp_ms);
    try std.testing.expectEqual(types.MessageKind.tool_call, messages[1].kind);
    try std.testing.expectEqualStrings("Read", messages[1].content);
    try std.testing.expectEqual(types.MessageRole.tool, messages[2].role);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[2].kind);
    try std.testing.expectEqualStrings("file contents", messages[2].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("done", messages[3].content);
}

test "ai_history_provider_opencode: transcript is fail-soft on missing fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "messages": [
        \\    {"parts": [{"type": "text", "text": "no info object"}]},
        \\    {"info": {"role": "user"}, "parts": [{"type": "text"}, {"type": "text", "text": "kept"}]},
        \\    {"info": {"role": "system"}, "parts": [{"type": "text", "text": "unknown role skipped"}]},
        \\    {"info": {"role": "assistant", "time": {"created": 5}}, "parts": "not an array"}
        \\  ]
        \\}
    ;

    const messages = try parseTranscript(allocator, json);
    defer freeTranscript(allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("kept", messages[0].content);
    try std.testing.expectEqual(@as(i64, 0), messages[0].timestamp_ms);
}

test "ai_history_provider_opencode: empty and malformed transcripts yield no messages" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "[]", "{}", "not json", "{\"messages\": {}}" }) |json| {
        const messages = try parseTranscript(allocator, json);
        defer freeTranscript(allocator, messages);
        try std.testing.expectEqual(@as(usize, 0), messages.len);
    }
}

test "ai_history_provider_opencode: malformed json is skipped but oom propagates" {
    const json =
        \\[{"id": "ses_ok", "title": "Fine"}]
    ;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseSessionList(failing.allocator(), json));
    try std.testing.expectError(error.OutOfMemory, parseTranscript(failing.allocator(), json));
}
