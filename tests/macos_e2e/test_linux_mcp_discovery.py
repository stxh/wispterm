"""Linux companion of test_mcp_discovery: mcp.json must not spawn a server at launch.

Current main (see src/main.zig) builds the MCP catalog from mcp.json + the disk
cache but does **not** spawn servers at startup — discovery is deferred to the
panel Test probe / first mcp_activate. The macOS original still asserts
initialize + tools/list at launch; that is stale. This companion keeps the
macOS file intact and asserts the Linux behavior that matches the app today:

- isolated launch with ~/.config/wispterm/mcp.json still starts (agent-control
  published, panes visible)
- the configured stdio server process is never spawned
"""
import json
import os
import sys
import time

import pytest

from tests.macos_e2e.conftest import CTL_BINARY, LINUX_BINARY, linux_only, require_linux_gui
from tests.macos_e2e.driver.linux import LinuxDriver

# Writes "spawned" the instant the process starts, before any JSON-RPC. That
# distinguishes "server never launched" from "launched but handshake incomplete".
_FAKE_MCP_SERVER = '''
import sys, json
record_path = sys.argv[1]
with open(record_path, "a") as f:
    f.write("spawned\\n")

def rec(method):
    with open(record_path, "a") as f:
        f.write(method + "\\n")

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    rec(method or "?")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
            "serverInfo": {"name": "e2e-fake", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "e2e_probe", "description": "probe", "inputSchema": {"type": "object"}}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
'''


def _recorded(path: str) -> list:
    if not os.path.exists(path):
        return []
    return open(path).read().split()


@pytest.mark.e2e
@linux_only
def test_mcp_json_does_not_spawn_server_at_startup():
    require_linux_gui()
    driver = LinuxDriver(binary=LINUX_BINARY, ctl_binary=CTL_BINARY)
    try:
        cfg_dir = driver._config_dir()
        os.makedirs(cfg_dir, exist_ok=True)

        server_path = os.path.join(driver.home, "fake_mcp_server.py")
        record_path = os.path.join(driver.home, "mcp_requests.log")
        with open(server_path, "w") as f:
            f.write(_FAKE_MCP_SERVER)
        with open(os.path.join(cfg_dir, "mcp.json"), "w") as f:
            json.dump(
                {"mcpServers": {"e2e": {"command": sys.executable, "args": [server_path, record_path]}}},
                f,
            )

        driver.launch()

        # launch() already blocked on agent-control.json + a live pane.
        disc = os.path.join(cfg_dir, "agent-control.json")
        assert os.path.exists(disc), "agent-control discovery file missing after launch with mcp.json"
        panes = driver.ctl.panes()
        assert panes.get("tabs"), "isolated launch with mcp.json published no tabs"

        # Give a slow async spawn a moment; startup discovery used to be
        # synchronous and would have written "spawned" before launch() returned.
        time.sleep(2.0)
        methods = _recorded(record_path)
        assert "spawned" not in methods, (
            "MCP server was spawned at startup; main.zig defers discovery to "
            f"the panel Test probe / mcp_activate. recorded {methods}"
        )
        assert "initialize" not in methods
        assert "tools/list" not in methods
    finally:
        driver.quit()
