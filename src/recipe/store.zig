//! Recipe store: named workspace layouts ("recipes").
//!
//! A recipe is a bare Session v2 JSON document (same wire format as
//! session_persist, no wrapper) stored one file per recipe under
//! `<config-dir>/recipes/<name>.json`. This module owns the pure logic and
//! filesystem I/O: name sanitizing, listing, save/load, import. UI state lives
//! in ui_state.zig / form_state.zig; restore lives in appwindow/tab.zig.
const std = @import("std");
const session_persist = @import("../session_persist.zig");

const log = std.log.scoped(.recipe_store);

/// Upper bound for a recipe name (and therefore the file stem).
pub const NAME_MAX: usize = 64;

/// Cap on recipe file size we will read into memory (matches loadSession).
pub const MAX_RECIPE_BYTES: usize = 1024 * 1024;

pub const RecipeInfo = struct {
    name: []u8,
    path: []u8,
};

/// Trim surrounding ASCII whitespace and validate the result as a recipe name.
/// Returns null when the name is unusable (empty, too long, contains a
/// path-illegal character, or collides with a Windows reserved device name).
/// On success the cleaned name is copied into `buf` and returned as a slice.
pub fn sanitizeName(buf: *[NAME_MAX]u8, raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > NAME_MAX) return null;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return null;
    for (trimmed) |ch| {
        if (ch < 0x20 or ch == 0x7f) return null;
        switch (ch) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return null,
            else => {},
        }
    }
    // Windows reserved device names apply to the stem regardless of extension,
    // so "con.json" would still be unwritable there.
    if (isWindowsReservedName(trimmed)) return null;
    // A trailing dot is silently stripped by Windows — forbid it outright.
    if (trimmed[trimmed.len - 1] == '.') return null;
    @memcpy(buf[0..trimmed.len], trimmed);
    return buf[0..trimmed.len];
}

fn isWindowsReservedName(name: []const u8) bool {
    const reserved = [_][]const u8{ "CON", "PRN", "AUX", "NUL" };
    for (reserved) |r| {
        if (std.ascii.eqlIgnoreCase(name, r)) return true;
    }
    if (name.len == 4 and name[3] >= '1' and name[3] <= '9') {
        const prefix = name[0..3];
        if (std.ascii.eqlIgnoreCase(prefix, "COM") or std.ascii.eqlIgnoreCase(prefix, "LPT")) return true;
    }
    return false;
}

/// Absolute (or cwd-relative) path of `dir_path/<name>.json`. `name` must
/// already be sanitized. Caller owns the returned slice.
pub fn recipePathForName(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

/// List every recipe in `dir_path` (`*.json`, stem is the recipe name),
/// sorted ascending by name. A missing directory yields an empty list.
/// Caller frees with freeRecipeList.
pub fn listRecipes(allocator: std.mem.Allocator, dir_path: []const u8) ![]RecipeInfo {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return try allocator.alloc(RecipeInfo, 0),
        else => return err,
    };
    defer dir.close();

    var items: std.ArrayListUnmanaged(RecipeInfo) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.path);
        }
        items.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue; // hidden files (incl. ".json")
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".json")) continue;
        const stem = std.fs.path.stem(entry.name);
        if (stem.len == 0 or stem.len > NAME_MAX) continue;
        const name = try allocator.dupe(u8, stem);
        errdefer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(path);
        try items.append(allocator, .{ .name = name, .path = path });
    }

    const slice = try items.toOwnedSlice(allocator);
    std.mem.sort(RecipeInfo, slice, {}, recipeLessThan);
    return slice;
}

fn recipeLessThan(_: void, a: RecipeInfo, b: RecipeInfo) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn freeRecipeList(allocator: std.mem.Allocator, items: []RecipeInfo) void {
    if (items.len == 0) return; // may be the static empty sentinel
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.path);
    }
    allocator.free(items);
}

/// Persist `session` as recipe `name` under `dir_path`, overwriting any
/// existing recipe of the same name (an explicit re-save updates in place).
pub fn saveRecipe(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    session: *const session_persist.Session,
) !void {
    var buf: [NAME_MAX]u8 = undefined;
    const clean = sanitizeName(&buf, name) orelse return error.InvalidName;
    const path = try recipePathForName(allocator, dir_path, clean);
    defer allocator.free(path);
    try session_persist.dumpSession(allocator, path, session.*);
}

/// Read and parse a recipe file. Unlike session_persist.loadSession this never
/// renames a corrupt file — a recipe is user data shared between machines, the
/// startup-session .bak convention does not apply. Callers own the returned
/// Parsed and must call `.deinit()`.
pub fn loadRecipe(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(session_persist.Session) {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, MAX_RECIPE_BYTES);
    defer allocator.free(bytes);
    var parsed = try session_persist.loadSessionFromString(allocator, bytes);
    session_persist.normalize(&parsed.value);
    return parsed;
}

/// Validate `bytes` as a Session document and store it as a recipe named after
/// `file_name`'s stem. Fails with error.InvalidName when the stem is unusable
/// and error.NameTaken when a recipe of that name already exists (importing
/// must not silently clobber a local recipe). Returns the stored recipe name
/// (caller frees).
pub fn importRecipeBytes(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    var parsed = session_persist.loadSessionFromString(allocator, bytes) catch return error.InvalidRecipe;
    defer parsed.deinit();
    session_persist.normalize(&parsed.value);

    var buf: [NAME_MAX]u8 = undefined;
    const clean = sanitizeName(&buf, std.fs.path.stem(file_name)) orelse return error.InvalidName;
    const path = try recipePathForName(allocator, dir_path, clean);
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch {
        // Not there — good, import must not clobber an existing recipe.
        try session_persist.dumpSession(allocator, path, parsed.value);
        return try allocator.dupe(u8, clean);
    };
    return error.NameTaken;
}

/// Delete recipe `name` from `dir_path`. error.FileNotFound propagates.
pub fn deleteRecipe(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !void {
    var buf: [NAME_MAX]u8 = undefined;
    const clean = sanitizeName(&buf, name) orelse return error.InvalidName;
    const path = try recipePathForName(allocator, dir_path, clean);
    defer allocator.free(path);
    try std.fs.cwd().deleteFile(path);
}

/// Restore-side degradation for recipes: a saved cwd may not exist on the
/// machine restoring the recipe (different checkout layout, shared file).
/// Nulls out every local-shell cwd that fails an existence probe so the
/// restored surface falls back to its default directory. Returns how many
/// cwds were dropped. Idempotent.
pub fn dropMissingLocalCwds(session: *session_persist.Session) usize {
    var dropped: usize = 0;
    for (session.tabs) |*tab| {
        dropMissingLocalCwdsInNode(&tab.tree, &dropped);
    }
    return dropped;
}

fn dropMissingLocalCwdsInNode(node: *session_persist.NodeSnap, dropped: *usize) void {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.kind != .terminal) return;
            switch (leaf.surface) {
                .local_shell => |*sh| {
                    const cwd = sh.cwd orelse return;
                    if (dirExists(cwd)) return;
                    log.info("recipe: dropping missing cwd {s}", .{cwd});
                    sh.cwd = null;
                    dropped.* += 1;
                },
                .ssh => {}, // remote cwd — cannot probe from here
            }
        },
        .split => |*sp| {
            dropMissingLocalCwdsInNode(sp.left, dropped);
            dropMissingLocalCwdsInNode(sp.right, dropped);
        },
    }
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

// ============================================================================
// Tests
// ============================================================================

fn makeTestSession(tabs: []session_persist.TabSnap) session_persist.Session {
    return .{ .active_tab = 0, .tabs = tabs };
}

test "sanitizeName accepts ordinary names and trims whitespace" {
    var buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("work", sanitizeName(&buf, "work").?);
    try std.testing.expectEqualStrings("my setup", sanitizeName(&buf, "  my setup  ").?);
    try std.testing.expectEqualStrings("工作台", sanitizeName(&buf, "工作台").?);
}

test "sanitizeName rejects empty, long, dotted and control-char names" {
    var buf: [NAME_MAX]u8 = undefined;
    try std.testing.expect(sanitizeName(&buf, "") == null);
    try std.testing.expect(sanitizeName(&buf, "   ") == null);
    try std.testing.expect(sanitizeName(&buf, ".") == null);
    try std.testing.expect(sanitizeName(&buf, "..") == null);
    try std.testing.expect(sanitizeName(&buf, "trail.") == null);
    try std.testing.expect(sanitizeName(&buf, "a" ** (NAME_MAX + 1)) == null);
    try std.testing.expect(sanitizeName(&buf, "bad\x07name") == null);
}

test "sanitizeName rejects path-illegal characters" {
    var buf: [NAME_MAX]u8 = undefined;
    for ([_]u8{ '/', '\\', ':', '*', '?', '"', '<', '>', '|' }) |ch| {
        const raw = [3]u8{ 'a', ch, 'b' };
        try std.testing.expect(sanitizeName(&buf, &raw) == null);
    }
}

test "sanitizeName rejects Windows reserved device names case-insensitively" {
    var buf: [NAME_MAX]u8 = undefined;
    for ([_][]const u8{ "CON", "con", "Prn", "AUX", "nul", "COM1", "com9", "LPT1", "lpt7" }) |name| {
        try std.testing.expect(sanitizeName(&buf, name) == null);
    }
    // Not reserved: prefixes that merely start the same way.
    try std.testing.expectEqualStrings("console", sanitizeName(&buf, "console").?);
    try std.testing.expectEqualStrings("com10", sanitizeName(&buf, "com10").?);
}

test "saveRecipe then loadRecipe round-trips a session" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const dir_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const leaf = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
        .cwd = "/home/user",
        .command = null,
    } } } };
    var tabs = [_]session_persist.TabSnap{.{ .tree = leaf, .title_override = "dev" }};
    const session = makeTestSession(&tabs);

    try saveRecipe(allocator, dir_path, "work", &session);

    const path = try recipePathForName(allocator, dir_path, "work");
    defer allocator.free(path);
    var loaded = try loadRecipe(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.tabs.len);
    try std.testing.expectEqualStrings("dev", loaded.value.tabs[0].title_override.?);
}

test "saveRecipe rejects an invalid name" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const dir_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    var tabs = [_]session_persist.TabSnap{.{ .tree = .{ .leaf = .{} } }};
    const session = makeTestSession(&tabs);
    try std.testing.expectError(error.InvalidName, saveRecipe(allocator, dir_path, "a/b", &session));
}

test "listRecipes returns stems sorted, ignoring non-json files" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const dir_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    try tmpdir.dir.writeFile(.{ .sub_path = "beta.json", .data = "{}" });
    try tmpdir.dir.writeFile(.{ .sub_path = "alpha.json", .data = "{}" });
    try tmpdir.dir.writeFile(.{ .sub_path = "notes.txt", .data = "not a recipe" });
    try tmpdir.dir.writeFile(.{ .sub_path = ".json", .data = "{}" }); // hidden — skipped

    const items = try listRecipes(allocator, dir_path);
    defer freeRecipeList(allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("alpha", items[0].name);
    try std.testing.expectEqualStrings("beta", items[1].name);
    try std.testing.expect(std.mem.endsWith(u8, items[0].path, "alpha.json"));
}

test "listRecipes on a missing directory yields an empty list" {
    const allocator = std.testing.allocator;
    const items = try listRecipes(allocator, "/nonexistent/wispterm-recipes-dir");
    defer freeRecipeList(allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "loadRecipe tolerates corrupt JSON with an error, not a .bak rename" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const dir_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    try tmpdir.dir.writeFile(.{ .sub_path = "broken.json", .data = "{ not json" });

    const path = try std.fs.path.join(allocator, &.{ dir_path, "broken.json" });
    defer allocator.free(path);
    try std.testing.expectError(error.SyntaxError, loadRecipe(allocator, path));
    // The file must still be there under its original name.
    try std.fs.cwd().access(path, .{});
}

test "importRecipeBytes stores valid bytes and rejects duplicates and junk" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const dir_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const doc =
        \\{"version":2,"active_tab":0,"tabs":[{"title_override":null,"focused_leaf":0,"zoomed_leaf":null,"tree":{"leaf":{"kind":"terminal","surface":{"local_shell":{"cwd":null,"command":null}},"preview":null}}}]}
    ;
    const stored_name = try importRecipeBytes(allocator, dir_path, "shared-setup.json", doc);
    defer allocator.free(stored_name);
    try std.testing.expectEqualStrings("shared-setup", stored_name);

    // Duplicate import must fail rather than overwrite.
    try std.testing.expectError(error.NameTaken, importRecipeBytes(allocator, dir_path, "shared-setup.json", doc));
    // Corrupt JSON must fail.
    try std.testing.expectError(error.InvalidRecipe, importRecipeBytes(allocator, dir_path, "junk.json", "nope"));
    // Unusable stem must fail.
    try std.testing.expectError(error.InvalidName, importRecipeBytes(allocator, dir_path, "a|b.json", doc));

    // The stored recipe loads back with one tab.
    const path = try recipePathForName(allocator, dir_path, "shared-setup");
    defer allocator.free(path);
    var loaded = try loadRecipe(allocator, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.tabs.len);
}

test "dropMissingLocalCwds nulls nonexistent directories only" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const allocator = std.testing.allocator;
    const existing = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(existing);

    var tabs = [_]session_persist.TabSnap{
        .{ .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = existing } } } } },
        .{ .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/nonexistent/wispterm-cwd-probe" } } } } },
        .{ .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } } },
        .{ .tree = .{ .leaf = .{ .surface = .{ .ssh = .{ .user = "u", .host = "h", .cwd = "/nonexistent/remote" } } } } },
    };
    var session = makeTestSession(&tabs);

    const dropped = dropMissingLocalCwds(&session);
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqualStrings(existing, tabs[0].tree.leaf.surface.local_shell.cwd.?);
    try std.testing.expect(tabs[1].tree.leaf.surface.local_shell.cwd == null);
    try std.testing.expect(tabs[2].tree.leaf.surface.local_shell.cwd == null);
    // SSH remote cwd is never probed.
    try std.testing.expectEqualStrings("/nonexistent/remote", tabs[3].tree.leaf.surface.ssh.cwd.?);
}
