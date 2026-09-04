# macOS UI E2E 测试

本地运行的端到端 GUI 测试:启动隔离的真实 `WispTerm.app`,断言终端正文(经控制通道)
与窗口/菜单状态(经 Accessibility)。

## 运行

**macOS:**

```bash
make test-macos-e2e
```

会先按本机架构构建 `macos-app` + `wisptermctl`,确保 `pytest` 在位(缺则
`pip install --user pytest`),再用 `/usr/bin/python3 -m pytest tests/macos_e2e`。

**Linux:**

```bash
make test-linux-e2e
```

会先按 `x86_64-linux-gnu` 构建 `wispterm` + `wisptermctl`,确保 `pytest` 在位(缺则
`pip install --user pytest`),再用 `python3 -m pytest tests/macos_e2e`。

可用环境变量指向预构建产物,跳过默认 `zig-out` 路径:

```bash
WISPTERM_E2E_BINARY=/path/to/wispterm WISPTERM_E2E_CTL=/path/to/wisptermctl \
  python3 -m pytest tests/macos_e2e -v
```

只跑无需 GUI 的纯逻辑单测:

```bash
python3 -m pytest tests/macos_e2e -m "not e2e"
```

## 前置条件

### macOS

- macOS + Xcode 或 Command Line Tools(提供 `/usr/bin/python3`)。
- **PyObjC**(非系统自带,需一次 pip):
  `/usr/bin/python3 -m pip install --user pyobjc-framework-Quartz pyobjc-framework-Cocoa`。
  未安装时 e2e 用例自动 skip 并给出该命令。
- **pytest**:`make` 入口会在缺失时自动 `pip install --user pytest`。
- 运行 pytest 的终端需在 **系统设置 → 隐私与安全性 → 辅助功能** 中授权
  (CGEvent 注入 + System Events 控制);未授权时 e2e 用例自动 skip 并提示。
- 解释器固定用 `/usr/bin/python3`(其 user-site 挂着 PyObjC);其他 python 可能没有 PyObjC。

### Linux

- Linux + X11/Wayland(需设置 `DISPLAY`)。
- **pytest**:`make` 入口会在缺失时自动 `pip install --user pytest`。
- **libsdl3** + **fontconfig**(运行时依赖):通常由包管理器提供,例如 Ubuntu/Debian 的
  `libsdl3-0` / `libfontconfig1`。
- **xdotool**(可选):真实键盘/鼠标路径需要它。控制通道测试(如 `test_smoke.py` 的
  echo 往返、`wisptermctl spawn`、OSC 标题、MCP discovery)在其缺失时也能跑;
  `test_linux_companion.py` 里的键编码/粘贴/分屏/标签/点击/缩放会 skip。
  安装:`sudo apt install xdotool`。
- **xclip**(可选):剪贴板读取需要它。`sudo apt install xclip`。
- **scrot**(可选):失败时截屏诊断需要它。`sudo apt install scrot`。

## 隔离

每次 session 用临时 `HOME`,在其中写 `config`(开启 `agent-control-enabled`、
关闭 `auto-update-check`)。Linux 写入 `$HOME/.config/wispterm`(与
`src/platform/dirs.zig` `configDirFromXdgOrHome` 一致;同时钉死
`XDG_CONFIG_HOME=$HOME/.config`,避免宿主机 XDG 泄漏)。所有 `wisptermctl`
调用带同一 `HOME` + XDG,只连测试实例,**不影响你正在用的开发实例**。

## 结构

- `driver/base.py` — 跨平台抽象接口(用例只依赖它)
- `driver/macos.py` — MacDriver:`open` 隔离启动 + CGEvent(键鼠,真实路径)+ osascript(菜单/AX)
  + wisptermctl(`send_text`/`get_text`,控制通道)
- `driver/linux.py` — LinuxDriver:隔离启动 + xdotool(键鼠,可选)+ wisptermctl(`send_text`/`get_text`/`spawn`,控制通道)。harness 的 `cmd` 在 Linux 上映射为 Ctrl(与 `keybind.zig` 默认一致)
- 纯逻辑模块(`panes`/`keycodes`/`wait`/`osascript` 构造/`ctl` 装配)有单元测试,无需 GUI
- `test_smoke.py` — 控制通道 echo 往返(启动 + 配置 + 控制服务 + shell + get-text),跨平台
- `test_linux.py` — Linux-only:首启无冻结(#599 回归),隔离 HOME;另有 config-dir / cmd→ctrl 单测
- `test_linux_companion.py` — Linux 伴侣用例:click-to-PTY、legacy 键编码、Ctrl+V 粘贴、窗口缩放→`stty size`、Shift+Enter CSI-u、键盘分屏/新标签、`wisptermctl spawn`、OSC 标题。不依赖 Quartz/AX/osascript
- `test_linux_mcp_discovery.py` — Linux 伴侣:带 `~/.config/wispterm/mcp.json` 仍能启动,且**不会**在启动时 spawn MCP server(discovery 推迟到 panel Test / `mcp_activate`;macOS 原用例的 launch handshake 断言已过时,保持不动)
- `test_menu.py` — Edit > Copy 菜单状态读取(osascript→AX,真实),macOS-only(Linux 无 AX,不移植)
- `test_quartz_input.py` — Quartz modifier flags 单测,macOS-only
- `test_keybinds.py` — 真实键盘入 PTY(跨平台);`test_cmd_c_copies_selection` 仍 xfail(无 select-all)
- `test_copilot_history.py` / `test_mcp_panel.py` — 模块级导入 MacDriver/Quartz,Linux 收集阶段忽略

## 已知限制(见 issue #279)

合成的输入**动作**(键盘、菜单点击)在"程序化启动"的测试实例里**不被处理**:事件能
到达 `-keyDown:`、`interpretKeyEvents:`→`insertText:` 也能触发,但字符/动作始终到不了
PTY;`File ▸ New Tab` 菜单点击也不改变标签数。仅**读取**(AX 菜单/窗口状态、`get-text`、
`panes`)和**控制通道写入**(`send-text`)可用。已排除环境因素:同样的 CGEvent 在本机能
正常打字进 TextEdit,`AXIsProcessTrusted()` 为真,Secure Input 关闭,实例为真实前台、窗口
为 key。疑似与"隔离实例启动即开 2 个 tab、`activeTab` 上报为 0"同源。

因此本期 harness 用**控制通道**做文本输入、用 **AX** 读菜单/窗口状态;真实键盘/菜单动作
路径待 [#279](https://github.com/xuzhougeng/wispterm/issues/279) 修复后,用 `driver/macos.py`
里保留的 `text()`/`key()`/`menu_click()`(CGEvent/osascript)直接接通,并取消
`test_keybinds.py` 的 skip。

## 扩展 / Windows

新增后端 `driver/windows.py`(`SendInput` via ctypes + UI Automation),
正文层(`get_text`/`wait_for`/`primary_pane`)直接复用;`conftest` 按平台选后端。

Linux 后端已实现(`driver/linux.py`,控制通道 + xdotool);Windows 按同样模式即可。
