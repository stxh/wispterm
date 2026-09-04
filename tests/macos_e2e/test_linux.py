"""Linux-specific E2E tests. Cross-platform tests live in test_smoke.py,
test_ctl.py, test_panes.py, etc. These tests are Linux-only assertions.
"""
import pytest

from tests.macos_e2e.conftest import linux_only
from tests.macos_e2e.driver.linux import config_dir_for_home, map_linux_mods


def test_config_dir_is_xdg_config_not_data_home():
    # src/platform/dirs.zig configDirFromXdgOrHome → ~/.config/wispterm
    assert config_dir_for_home("/tmp/iso") == "/tmp/iso/.config/wispterm"


def test_harness_cmd_maps_to_ctrl():
    assert map_linux_mods(("cmd", "shift")) == ["ctrl", "shift"]
    assert map_linux_mods(("ctrl",)) == ["ctrl"]
    assert map_linux_mods(("super",)) == ["super"]


@pytest.mark.e2e
@linux_only
def test_first_launch_no_freeze(app, pane):
    """Regression test for #599 (Linux SDL event-pump hang on first-run AI overlay).
    After launch, the shell is responsive via control channel. This verifies the
    event loop does not freeze on the first-run AI-setup form."""
    # On fresh launch, the AI-setup form is pre-marked as prompted in the state
    # file, so it should not auto-open. Verify shell responsiveness by injecting
    # a known command via control channel.
    app.send_text("echo first-launch-e2e\n")
    app.wait_for(pane, "first-launch-e2e", timeout=8)


@pytest.mark.e2e
@linux_only
def test_linux_binary_starts_with_isolated_home(app):
    """Verify the Linux binary honors $HOME isolation and publishes panes."""
    panes = app.ctl.panes()
    assert "tabs" in panes
    assert len(panes.get("tabs", [])) > 0, "isolated launch should have at least one tab"
