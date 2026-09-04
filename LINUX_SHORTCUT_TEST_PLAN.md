# Linux Keyboard Shortcut Test Plan

## Issue
Several documented keyboard shortcuts were non-functional on Linux (Debian 13, XFCE):
1. Paste: `Ctrl+V` (and `Ctrl+Shift+V`)
2. Command center: `Ctrl+Shift+P`
3. Split right/down: `Ctrl+Shift++` / `Ctrl+Shift+-`

## Root Cause
SDL3 event handler only processed special keys (arrows, F-keys) via scancode lookup. Alphanumeric keys with modifiers returned null from `keyCodeFromScancode()`, so no KeyEvent was created.

## Fix
- Added `keyCodeFromSdlKeycode()` to map SDL logical keycodes to neutral key codes
- Updated SDL_EVENT_KEY_DOWN handler to check keycode when scancode fails and modifiers are pressed
- Preserves existing behavior for text input without modifiers

## Test Procedure

### Prerequisites
- Linux system with X11 or Wayland
- WispTerm built from branch `cursor/fix-linux-keyboard-shortcuts-1b5a`

### Build
```bash
cd /workspace
zig build
```

### Test 1: Paste in Terminal (Ctrl+V)
1. Open a browser and copy text: `echo hello-user`
2. Launch WispTerm: `./zig-out/bin/wispterm`
3. Press `Ctrl+V` in the terminal
4. **Expected**: Text appears at the prompt
5. **Verify**: Can also test `Ctrl+Shift+V` (paste image fallback)

### Test 2: Command Center (Ctrl+Shift+P)
1. With WispTerm open, press `Ctrl+Shift+P`
2. **Expected**: Command palette/center opens with search field
3. Type a few characters to verify search works
4. Press `Escape` to close
5. **Verify**: Can also test `Ctrl+P` (documented alternate)

### Test 3: Split Panes (Ctrl+Shift++ and Ctrl+Shift+-)
1. Press `Ctrl+Shift++` (or `Ctrl+Shift+=` depending on keyboard)
2. **Expected**: New pane appears to the right of current pane
3. Press `Ctrl+Shift+-`
4. **Expected**: New pane appears below current pane
5. **Verify**: Can navigate between panes with `Alt+Arrow` keys

### Test 4: Existing Shortcuts Still Work
1. Copy text: Select with mouse, press `Ctrl+Shift+C`
2. **Expected**: Text copied to clipboard, can paste in browser
3. New tab: `Ctrl+Shift+T`
4. **Expected**: New tab opens
5. Settings: `Ctrl+,`
6. **Expected**: Settings page opens

### Test 5: Normal Typing Unaffected
1. Type regular text without modifiers: `ls -la`
2. **Expected**: Characters appear normally
3. Type with Shift: `HELLO`
4. **Expected**: Uppercase letters appear
5. **Verify**: No double input or missing characters

## Regression Checks
- Arrow keys work: `Up`, `Down`, `Left`, `Right`
- F5 works (if bound to a function)
- Tab completion works: type `cd /h` then `Tab`
- Escape works to close overlays
- Mouse copy/paste still works

## Known Limitations
- No changes to Windows or macOS input handling
- SDL3-specific fix (does not affect other backends)
- Keyboard layout dependent (QWERTY tested)

## Exit Criteria
All 5 test procedures pass without errors or unexpected behavior.
