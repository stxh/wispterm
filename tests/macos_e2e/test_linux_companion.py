"""Linux companions for portable E2E cases the macOS originals skip as harness gaps.

macOS files stay intact (AX/Quartz/osascript). These drive the same behaviors
through LinuxDriver + wisptermctl. Edit-menu AX and Quartz modifier-flag tests
have no Linux equivalent and stay skipped.
"""
import os
import re
import subprocess
import sys
import time

import pytest

from tests.macos_e2e.conftest import (
    LINUX_BINARY,
    CTL_BINARY,
    linux_only,
    require_linux_gui,
    require_xclip,
    require_xdotool,
)
from tests.macos_e2e.driver import wait
from tests.macos_e2e.driver.linux import LinuxDriver

_PY = sys.executable

# ---- shared helpers -------------------------------------------------------

def _need_xdotool():
    require_xdotool()


def _tab_count(app) -> int:
    return len(app.ctl.panes().get("tabs", []))


def _active_surface_count(app) -> int:
    panes = app.ctl.panes()
    tabs = panes.get("tabs", [])
    active = panes.get("activeTab", 0)
    tab = next((t for t in tabs if t.get("index") == active and t.get("surfaces")), None)
    if tab is None:
        tab = next((t for t in tabs if t.get("surfaces")), None)
    return len(tab.get("surfaces", [])) if tab else 0


def _wait_count(read, n: int, label: str, timeout: float = 6.0):
    box = {}

    def check():
        box["last"] = read()
        return True if box["last"] == n else None

    try:
        wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"expected {n} {label}, last saw {box.get('last')}")


def _wait_overlay(app, value: str, timeout: float = 4.0):
    box = {}

    def check():
        box["last"] = app.ui_state().get("activeOverlay")
        return True if box["last"] == value else None

    try:
        wait.wait_until(check, timeout=timeout, interval=0.15)
    except wait.TimeoutError:
        raise AssertionError(f"expected overlay {value!r}, last saw {box.get('last')!r}")


def _pty_size(app, pane: str, tag: str):
    app.send_text("\x03", pane)
    time.sleep(0.2)
    app.send_text(f"echo W''SZ{tag} $(stty size)\n", pane)
    pat = re.compile(rf"WSZ{tag} (\d+) (\d+)")

    def check():
        m = pat.search(app.get_text(pane))
        return (int(m.group(1)), int(m.group(2))) if m else None

    return wait.wait_until(check, timeout=8, interval=0.2)


def _focused_title(app, pane: str) -> str:
    for tab in app.ctl.panes().get("tabs", []):
        for s in tab.get("surfaces", []):
            if s.get("id") == pane:
                return s.get("title", "")
    return ""


# ---- 1. click-to-PTY ------------------------------------------------------

_MOUSE_PROBE = r'''
import os, sys, termios, tty, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(1, b"\x1b[?1000h\x1b[?1006h")
    os.write(1, b"MOUSEREADY\r\n")
    r, _, _ = select.select([fd], [], [], 10)
    data = os.read(fd, 64) if r else b""
finally:
    os.write(1, b"\x1b[?1006l\x1b[?1000l")
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
os.write(1, b"MOUSE=" + data.hex().encode() + b"\r\n")
'''
_SGR_PREFIX = b"\x1b[<".hex()


@pytest.mark.e2e
@linux_only
def test_left_click_reaches_pty_as_mouse_report(app, pane):
    _need_xdotool()
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.send_text("\x03", pane)

    probe_path = os.path.join(app.home, "mouse_probe.py")
    with open(probe_path, "w") as f:
        f.write(_MOUSE_PROBE)

    app.send_text(f"{_PY} {probe_path}\n", pane)
    app.wait_for(pane, "MOUSEREADY", timeout=15)

    x, y, w, h = app.window_rect()
    app.click(x + w // 2, y + int(h * 0.6))
    app.wait_for(pane, f"MOUSE={_SGR_PREFIX}", timeout=15)


# ---- 2–6. legacy key encoding --------------------------------------------

_KEY_PROBE = r'''
import os, sys, termios, tty, select
tok = (sys.argv[1] if len(sys.argv) > 1 else "X").encode()
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)

def read(timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    return os.read(fd, 64) if r else b""

try:
    tty.setraw(fd)
    os.write(1, b"\x1b[<u")
    os.write(1, b"READY:" + tok + b"\r\n")
    keybytes = read(10)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
os.write(1, b"KB:" + tok + b"=" + keybytes.hex().encode() + b"\r\n")
'''

_KEY_CASES = [
    ("plain_enter", ("return",), b"\r"),
    ("shift_enter_legacy", ("return", "shift"), b"\r"),
    ("ctrl_c", ("c", "ctrl"), b"\x03"),
    ("tab", ("tab",), b"\t"),
    ("escape", ("escape",), b"\x1b"),
]


@pytest.mark.e2e
@linux_only
@pytest.mark.parametrize("token,keyargs,expected", _KEY_CASES, ids=[c[0] for c in _KEY_CASES])
def test_legacy_key_encoding_reaches_pty(app, pane, token, keyargs, expected):
    _need_xdotool()
    app.ensure_keyboard_ready(pane)

    probe_path = os.path.join(app.home, "key_encoding_probe.py")
    with open(probe_path, "w") as f:
        f.write(_KEY_PROBE)

    app.send_text("\x03", pane)
    app.send_text(f"{_PY} {probe_path} {token}\n", pane)
    app.wait_for(pane, f"READY:{token}", timeout=15)
    app.key(*keyargs)
    app.wait_for(pane, f"KB:{token}={expected.hex()}", timeout=15)


# ---- 9. Ctrl+V paste ------------------------------------------------------

_PASTE_MARKER = "WISPTERM_LINUX_PASTE_42"


@pytest.mark.e2e
@linux_only
def test_ctrl_v_pastes_clipboard_into_pty(app, pane):
    _need_xdotool()
    require_xclip()
    subprocess.run(
        ["xclip", "-selection", "clipboard"],
        input=_PASTE_MARKER, text=True, check=True,
    )

    app.focus()
    app.ensure_keyboard_ready(pane)
    app.send_text("\x03", pane)
    time.sleep(0.3)

    # Shared harness spelling: cmd → Ctrl on Linux (Ctrl+V paste).
    app.key("v", "cmd")
    try:
        app.wait_for(pane, _PASTE_MARKER, timeout=8)
    finally:
        app.send_text("\x03", pane)


# ---- 11. window resize → stty size ----------------------------------------

@pytest.mark.e2e
@linux_only
def test_window_resize_propagates_to_pty(app, pane):
    _need_xdotool()
    w0, h0 = app.window_size()
    before = _pty_size(app, pane, "A")
    try:
        app.set_window_size(max(w0 - 160, 400), max(h0 - 120, 300))
        time.sleep(0.5)
        after = _pty_size(app, pane, "B")
        assert after != before, f"PTY size unchanged after window resize: {before} -> {after}"
    finally:
        app.set_window_size(w0, h0)


# ---- 12. Shift+Enter CSI-u ------------------------------------------------

_KITTY_PROBE = r'''
import os, sys, termios, tty, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)

def read(timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    return os.read(fd, 64) if r else b""

try:
    tty.setraw(fd)
    os.write(1, b"\x1b[?u")
    qresp = read(5)
    os.write(1, b"\x1b[>1u")
    os.write(1, b"KITTYREADY\r\n")
    keybytes = read(10)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.write(1, b"\x1b[<u")
os.write(1, b"QRESP=" + qresp.hex().encode()
         + b" KEYBYTES=" + keybytes.hex().encode() + b"\r\n")
'''
_SHIFT_ENTER = b"\x1b[13;2u".hex()
_QUERY_REPLY_PREFIX = b"\x1b[?".hex()


@pytest.mark.e2e
@linux_only
def test_shift_enter_sends_kitty_csi_u(app, pane):
    _need_xdotool()
    app.ensure_keyboard_ready(pane)

    probe_path = os.path.join(app.home, "kitty_shift_enter_probe.py")
    with open(probe_path, "w") as f:
        f.write(_KITTY_PROBE)

    app.send_text("\x03", pane)
    app.send_text(f"{_PY} {probe_path}\n", pane)
    app.wait_for(pane, "KITTYREADY", timeout=15)
    app.key("return", "shift")
    app.wait_for(pane, f"KEYBYTES={_SHIFT_ENTER}", timeout=15)

    screen = app.get_text(pane)
    assert f"QRESP={_QUERY_REPLY_PREFIX}" in screen, (
        f"terminal did not answer the Kitty keyboard query; screen:\n{screen}"
    )


# ---- 13. split via keyboard -----------------------------------------------

@pytest.mark.e2e
@linux_only
def test_split_adds_surface_to_active_tab(app, pane):
    _need_xdotool()
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.key("escape")
    base = _active_surface_count(app)

    # Ctrl+Shift+= → split_right (harness cmd → ctrl).
    app.key("equal", "cmd", "shift")
    _wait_count(lambda: _active_surface_count(app), base + 1, "surfaces")

    app.key("w", "cmd", "shift")
    time.sleep(0.3)
    app.key("return")
    _wait_count(lambda: _active_surface_count(app), base, "surfaces")


# ---- 14. new tab / close via keyboard + ctl spawn -------------------------

@pytest.mark.e2e
@linux_only
def test_new_tab_and_close_via_keyboard(app, pane):
    _need_xdotool()
    app.focus()
    app.ensure_keyboard_ready(pane)
    app.key("escape")
    _wait_overlay(app, "none")
    base = _tab_count(app)

    # Ctrl+Shift+T → session launcher; Enter → new terminal tab.
    app.key("t", "cmd", "shift")
    _wait_overlay(app, "session_launcher")
    app.key("return")
    _wait_count(lambda: _tab_count(app), base + 1, "tabs")

    app.key("w", "cmd", "shift")
    time.sleep(0.3)
    app.key("return")
    _wait_count(lambda: _tab_count(app), base, "tabs")


@pytest.mark.e2e
@linux_only
def test_spawn_opens_new_default_shell_tab():
    """ctl-only new-tab: `wisptermctl spawn` with an empty command."""
    require_linux_gui()
    driver = LinuxDriver(binary=LINUX_BINARY, ctl_binary=CTL_BINARY)
    driver.launch()
    try:
        base = _tab_count(driver)
        driver.ctl.spawn()
        _wait_count(lambda: _tab_count(driver), base + 1, "tabs")
    finally:
        driver.quit()


# ---- 15. OSC title --------------------------------------------------------

_TITLE_MARKER = "WISPTERM_LINUX_E2E_TITLE"
_TITLE_SCRIPT = (
    "import sys, time\n"
    f'sys.stdout.write("\\x1b]0;{_TITLE_MARKER}\\x07")\n'
    "sys.stdout.flush()\n"
    "time.sleep(4)\n"
)


@pytest.mark.e2e
@linux_only
def test_osc_title_sets_surface_title(app, pane):
    script_path = os.path.join(app.home, "osc_title_probe.py")
    with open(script_path, "w") as f:
        f.write(_TITLE_SCRIPT)

    app.send_text("\x03", pane)
    time.sleep(0.3)
    app.send_text(f"{_PY} {script_path}\n", pane)

    box = {}

    def check():
        box["last"] = _focused_title(app, pane)
        return True if _TITLE_MARKER in box["last"] else None

    try:
        wait.wait_until(check, timeout=8.0, interval=0.2)
    except wait.TimeoutError:
        raise AssertionError(f"OSC title not reflected in panes; last title={box.get('last')!r}")
