import pytest
from tests.macos_e2e.driver.ctl import Ctl
from tests.macos_e2e.driver.wait import TimeoutError as WaitTimeout


class _FakeClock:
    def __init__(self):
        self.t = 0.0

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s


def test_wait_for_matches_eventually(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    seq = iter(["", "loading", "ready: hello"])
    monkeypatch.setattr(c, "get_text", lambda pane, recent=None: next(seq))
    c.wait_for("pane1", "hello", timeout=10, interval=1, clock=_FakeClock())  # no raise


def test_wait_for_times_out(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    monkeypatch.setattr(c, "get_text", lambda pane, recent=None: "nope")
    with pytest.raises(WaitTimeout):
        c.wait_for("pane1", "hello", timeout=2, interval=1, clock=_FakeClock())


def test_spawn_bare_is_plain_shell_tab(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    seen = []
    monkeypatch.setattr(c, "_run", lambda args, timeout=10.0: seen.append(args) or "")
    c.spawn()
    assert seen == [["spawn"]]


def test_spawn_cwd_and_command(monkeypatch):
    c = Ctl(home="/tmp/x", binary="/bin/false")
    seen = []
    monkeypatch.setattr(c, "_run", lambda args, timeout=10.0: seen.append(args) or "")
    c.spawn("bash", "-lc", "true", cwd="/work")
    assert seen == [["spawn", "--cwd", "/work", "--", "bash", "-lc", "true"]]


def test_ctl_env_pins_xdg_config_under_home():
    c = Ctl(home="/tmp/iso-home", binary="/bin/false")
    env = c._env()
    assert env["HOME"] == "/tmp/iso-home"
    assert env["XDG_CONFIG_HOME"] == "/tmp/iso-home/.config"
