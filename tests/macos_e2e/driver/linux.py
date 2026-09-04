"""Linux backend: launches WispTerm binary in isolated HOME, uses wisptermctl
for terminal text, and xdotool for keyboard/mouse when available. Falls back to
control-channel-only mode when xdotool is missing (same pattern as macOS #279).
"""
import os
import shutil
import subprocess
import tempfile
import time

from . import wait
from .base import ItemState
from .ctl import Ctl
from .panes import primary_pane_id

# Deterministic base config (reuses macOS convention). Language is pinned to
# English so command-palette entries match their English names regardless of
# the host locale.
_CONFIG = (
    "agent-control-enabled = true\n"
    "auto-update-check = false\n"
    "font-size = 14\n"
    "language = en\n"
)


def config_dir_for_home(home: str) -> str:
    """Config dir the Linux app actually reads: ~/.config/wispterm.

    Must match ``src/platform/dirs.zig`` ``configDirFromXdgOrHome`` (not
    XDG_DATA_HOME / ~/.local/share). The isolated launch sets XDG_CONFIG_HOME
    to ``{home}/.config`` so a host XDG_CONFIG_HOME cannot leak in.
    """
    return os.path.join(home, ".config", "wispterm")


def map_linux_mods(mods):
    """Map harness modifier names to xdotool keysyms.

    Shared tests pass ``cmd`` for the primary chord (Cmd+Shift+P on macOS).
    Linux defaults keep Ctrl (``src/keybind.zig``), so ``cmd`` → ``ctrl`` here
    only. Pass ``super`` when Super is actually required.
    """
    mod_map = {"cmd": "ctrl", "ctrl": "ctrl", "shift": "shift", "alt": "alt", "super": "super"}
    return [mod_map.get(m.lower(), m) for m in mods]


class LinuxDriver:
    def __init__(self, binary: str, ctl_binary: str):
        # binary: .../zig-out/bin/wispterm ; ctl_binary: .../zig-out/bin/wisptermctl
        self.binary = binary
        self.ctl_binary = ctl_binary
        self.home = tempfile.mkdtemp(prefix="wispterm-e2e-")
        self.proc = None
        self.ctl = Ctl(home=self.home, binary=self.ctl_binary)
        self._xdotool = shutil.which("xdotool")
        self._kbd_token = 0

    # ---- lifecycle ----
    def _config_dir(self) -> str:
        return config_dir_for_home(self.home)

    def _isolated_env(self) -> dict:
        env = dict(os.environ)
        env["HOME"] = self.home
        # Pin XDG so the app and wisptermctl agree with _config_dir(), even when
        # the host session exports XDG_CONFIG_HOME / XDG_DATA_HOME.
        env["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        env["XDG_DATA_HOME"] = os.path.join(self.home, ".local", "share")
        env["XDG_STATE_HOME"] = os.path.join(self.home, ".local", "state")
        env["XDG_CACHE_HOME"] = os.path.join(self.home, ".cache")
        return env

    def launch(self, *, cols: int = 80, rows: int = 24) -> None:
        cfg_dir = self._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)
        # window-width/height are the initial terminal grid in CELLS (same
        # convention as macOS).
        with open(os.path.join(cfg_dir, "config"), "w") as f:
            f.write(_CONFIG)
            f.write(f"window-width = {cols}\n")
            f.write(f"window-height = {rows}\n")
        # Pre-mark the first-run wizard as already prompted so the AI-setup form
        # does not auto-open (reuses macOS convention).
        with open(os.path.join(cfg_dir, "state"), "w") as f:
            f.write("ai-setup-prompted = 1\n")

        # DISPLAY is inherited from the test process; if unset, the skip
        # machinery in conftest has already excluded this run.
        self.proc = subprocess.Popen(
            [self.binary], env=self._isolated_env(),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        # control server publishes its discovery file inside our isolated HOME
        disc = os.path.join(cfg_dir, "agent-control.json")
        wait.wait_until(lambda: os.path.exists(disc), timeout=15, interval=0.2)
        wait.wait_until(self._has_terminal_surface, timeout=15, interval=0.2)
        self.focus()

    def _has_terminal_surface(self) -> bool:
        try:
            primary_pane_id(self.ctl.panes())
            return True
        except Exception:
            return False

    def quit(self) -> None:
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            except Exception:
                pass
            self.proc = None
        shutil.rmtree(self.home, ignore_errors=True)

    def focus(self) -> None:
        # Best-effort window activation via xdotool when available. If xdotool
        # is missing or X11 focus fails, we fall back to control-channel-only
        # mode (the tests skip real-input paths when xdotool is absent).
        if self._xdotool and self.proc:
            try:
                subprocess.run(
                    [self._xdotool, "search", "--pid", str(self.proc.pid), "--name", "WispTerm", "windowactivate"],
                    capture_output=True, timeout=3, check=False
                )
                time.sleep(0.3)  # let activation settle before posting events
            except Exception:
                pass

    # ---- discovery ----
    def primary_pane(self) -> str:
        return primary_pane_id(self.ctl.panes())

    def ui_state(self) -> dict:
        # Overlay semantic state (active overlay, command-palette selection/filter).
        return self.ctl.ui_state()

    # ---- real input ----
    # xdotool is best-effort; tests skip these methods when xdotool is missing.
    # Space successive keystrokes apart to avoid IM races (same pattern as macOS).
    _KEY_GAP = 0.04

    def key(self, key_name: str, *mods: str) -> None:
        if not self._xdotool:
            raise RuntimeError("xdotool unavailable; real input skipped in this run")
        self.focus()
        # xdotool uses X11 keysym names; map common ones. Extend as needed.
        keysym_map = {
            "return": "Return",
            "escape": "Escape",
            "tab": "Tab",
            "space": "space",
            "backspace": "BackSpace",
            "delete": "Delete",
            "up": "Up",
            "down": "Down",
            "left": "Left",
            "right": "Right",
            "equal": "equal",
            "plus": "plus",
            "minus": "minus",
        }
        keysym = keysym_map.get(key_name.lower(), key_name)
        # xdotool modifier syntax: key --clearmodifiers ctrl+shift+p
        # Harness "cmd" maps to Ctrl on Linux (see map_linux_mods).
        if mods:
            mods_str = "+".join(map_linux_mods(mods))
            keysym = f"{mods_str}+{keysym}"
        subprocess.run([self._xdotool, "key", "--clearmodifiers", keysym], check=False)
        time.sleep(self._KEY_GAP)

    def text(self, s: str) -> None:
        if not self._xdotool:
            raise RuntimeError("xdotool unavailable; real input skipped in this run")
        self.focus()
        for ch in s:
            if ch in ("\n", "\r"):
                self.key("return")
            else:
                subprocess.run([self._xdotool, "type", "--", ch], check=False)
                time.sleep(self._KEY_GAP)

    def ensure_keyboard_ready(self, pane: str = None, tries: int = 6) -> None:
        """Warm up the OS keyboard path and block until a keystroke demonstrably
        reaches the shell. On Linux, xdotool input can be dropped on the first
        burst after a fresh launch (same IM race as macOS #279). A dropped burst
        leaves no partial text, so retrying is safe."""
        if not self._xdotool:
            return  # control-channel-only mode does not need warmup
        pane = pane or self.primary_pane()
        for _ in range(tries):
            self._kbd_token += 1
            sentinel = f"__wisp_kbd_ready_{self._kbd_token}__"
            self.focus()
            self.text(f": {sentinel}")
            self.key("return")
            try:
                self.ctl.wait_for(pane, sentinel, timeout=1.5)
                return
            except wait.TimeoutError:
                continue
        raise AssertionError("OS keyboard input path never became ready")

    def click(self, x: int, y: int, *, count: int = 1) -> None:
        if not self._xdotool:
            raise RuntimeError("xdotool unavailable; real input skipped in this run")
        self.focus()
        subprocess.run([self._xdotool, "mousemove", str(x), str(y)], check=False)
        for _ in range(count):
            subprocess.run([self._xdotool, "click", "1"], check=False)

    def _window_id(self) -> str:
        """xdotool id of the test instance's WispTerm window."""
        if not self._xdotool or not self.proc:
            raise RuntimeError("xdotool unavailable; window geometry skipped in this run")
        out = subprocess.run(
            [self._xdotool, "search", "--onlyvisible", "--pid", str(self.proc.pid), "--name", "WispTerm"],
            capture_output=True, text=True, timeout=3, check=False,
        )
        ids = out.stdout.split()
        if not ids:
            # --onlyvisible can miss a just-mapped window; retry without it.
            out = subprocess.run(
                [self._xdotool, "search", "--pid", str(self.proc.pid), "--name", "WispTerm"],
                capture_output=True, text=True, timeout=3, check=False,
            )
            ids = out.stdout.split()
        if not ids:
            raise RuntimeError("WispTerm window id not found")
        return ids[-1]

    def window_rect(self):
        """(x, y, w, h) of the test window in screen pixels (xdotool space)."""
        wid = self._window_id()
        out = subprocess.run(
            [self._xdotool, "getwindowgeometry", "--shell", wid],
            capture_output=True, text=True, timeout=3, check=False,
        )
        vals = {}
        for line in out.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                try:
                    vals[k] = int(v)
                except ValueError:
                    continue
        try:
            return vals["X"], vals["Y"], vals["WIDTH"], vals["HEIGHT"]
        except KeyError:
            raise RuntimeError(f"xdotool getwindowgeometry failed: {out.stdout!r} {out.stderr!r}")

    def window_size(self):
        """Current (w, h) in screen pixels."""
        _, _, w, h = self.window_rect()
        return w, h

    def set_window_size(self, w: int, h: int) -> None:
        """Resize via xdotool (non-AX). Used to drive PTY stty-size changes."""
        wid = self._window_id()
        subprocess.run(
            [self._xdotool, "windowsize", wid, str(w), str(h)],
            capture_output=True, timeout=3, check=False,
        )

    # ---- menu / window ----
    # Linux has no AX menu API. menu_* stay NotImplemented; window geometry is
    # driveable via xdotool (window_rect / set_window_size).
    def menu_click(self, *path: str) -> None:
        raise NotImplementedError("menu automation not implemented on Linux")

    def menu_item_state(self, *path: str) -> ItemState:
        raise NotImplementedError("menu automation not implemented on Linux")

    def window_attr(self, name: str) -> str:
        # Best-effort window geometry via xwininfo when the user requests it.
        # xwininfo is in the x11-utils package on Debian/Ubuntu; fall back to
        # "unavailable" when missing.
        if not shutil.which("xwininfo"):
            return f"{name}=unavailable"
        try:
            out = subprocess.run(
                ["xwininfo", "-pid", str(self.proc.pid)],
                capture_output=True, text=True, timeout=3, check=False
            )
            # Parse output lines like "  Width: 800" or "  Absolute upper-left X:  10"
            for line in out.stdout.splitlines():
                if name.lower() in line.lower():
                    return line.strip()
        except Exception:
            pass
        return f"{name}=unknown"

    # ---- terminal text ----
    def get_text(self, pane: str, recent=None) -> str:
        return self.ctl.get_text(pane, recent)

    def send_text(self, data: str, pane: str = None) -> None:
        # Control-channel text injection (bypasses the OS input path; see #279).
        self.ctl.send_text(pane or self.primary_pane(), data)

    def wait_for(self, pane: str, pattern: str, timeout: float = 5.0) -> None:
        self.ctl.wait_for(pane, pattern, timeout=timeout)

    def read_clipboard(self) -> str:
        # Best-effort clipboard read via xclip when available.
        if not shutil.which("xclip"):
            raise NotImplementedError("xclip not installed; clipboard read unavailable")
        out = subprocess.run(
            ["xclip", "-selection", "clipboard", "-o"],
            capture_output=True, text=True, timeout=3, check=False
        )
        return out.stdout

    def screenshot(self, path: str) -> bool:
        """Best-effort PNG capture via scrot when available. Returns False (never
        raises) if capture is unavailable, so a diagnostic dump never masks the
        original test failure."""
        if not shutil.which("scrot"):
            return False
        try:
            self.focus()
            subprocess.run(["scrot", "-u", path], timeout=10, check=True)
            return os.path.exists(path)
        except Exception:
            return False
