## Summary

This PR brings the dev branch up to date with all persistent UI features and bug fixes.

## Changes

### Persistent UI Features (5 identity features)
1. **Icon-only sidebar with hover tooltip** — 48px sidebar with centered emoji icons. Hover shows tooltip with tab title + cwd + git branch (opaque background, 350ms dwell, 3s auto-dismiss).
2. **Right-click sidebar tab always shows confirmation dialog** — Never directly closes; opens closeConfirmOpen with .running_program or .window_generic variant.
3. **Plus button** — Left-click = new terminal tab, right-click = session launcher dialog.
4. **Terminal process exit closes tab/window** — sweepExitedSurfaces() runs at top of main loop; also polls process exit status directly (handles ConPTY pipe-stays-open case).
5. **File-explorer toggle on the titlebar** — Folder icon next to sidebar toggle. Clicking toggles global file explorer (same as Ctrl+Shift+Alt+E). Suppressed on non-terminal tabs.

### Bug Fixes
- **Sidebar tooltip not appearing**: Fixed chicken-and-egg between event-driven render gate and renderer-side hover detection by requesting repaint in handleMouseMove at the very start.
- **Terminal exit not closing tab**: isExited() now returns true for both .exited and .failed states. sweepExitedSurfaces() polls process exit status directly when read thread is blocked.
- **Sidebar plus button not clickable**: sidebarPlusButton hit test was checking header area (header_h=0 in icon-only mode). Rewrote to check the row after the tab list.
- **Icon centering**: Color emoji advance width differs from visual width; added titlebarGlyphVisualWidth() for proper centering.
- **File explorer on non-terminal tabs**: toggleFileExplorer() now checks isActiveTabTerminal() and returns early if false.

### Documentation
- New docs/persistent-ui-behaviors.md with full implementation details for all 5 features.
- Updated AGENTS.md with the 5 persistent UI features and merge-check grep list.

### Other
- build-env.ps1 helper for setting up the Zig build environment on Windows.
- Single-instance guard (src/platform/single_instance_windows.zig).
- WSL probe guard and preview close guard fixes.
- Removed accidentally committed AppWindow.obj binary.
