//! Feature-owned UI state for workspace recipes: the naming-form instance and
//! the palette-visible recipe list cache. Kept out of renderer/overlays.zig on
//! purpose (AGENTS.md: new UI state lives in an explicit state struct or a
//! feature-owned module, never as another g_* in the integration layer).
//!
//! `threadlocal` matches the app model: each window runs on its own thread, so
//! every window gets an independent form and list cache.
const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");
const form_state = @import("form_state.zig");
const store = @import("store.zig");

threadlocal var g_form: form_state.State = .{};

threadlocal var g_list: []store.RecipeInfo = &.{};
threadlocal var g_list_loaded: bool = false;

pub fn form() *form_state.State {
    return &g_form;
}

/// Recipes currently cached for the command palette (index-addressed by the
/// palette's `.recipe` items). Empty until ensureRecipeList runs.
pub fn recipeItems() []const store.RecipeInfo {
    return g_list;
}

/// Load the recipe list once per palette session; call invalidateRecipeList
/// when the palette opens so freshly saved/imported/deleted files show up.
pub fn ensureRecipeList(allocator: std.mem.Allocator) void {
    if (g_list_loaded) return;
    g_list_loaded = true;
    const dir_path = platform_dirs.recipesDir(allocator) catch return;
    defer allocator.free(dir_path);
    g_list = store.listRecipes(allocator, dir_path) catch &.{};
}

/// Drop the cached list so the next ensureRecipeList re-reads the directory.
pub fn invalidateRecipeList(allocator: std.mem.Allocator) void {
    store.freeRecipeList(allocator, g_list);
    g_list = &.{};
    g_list_loaded = false;
}
