.PHONY: debug release clean update-ghostty test-macos-e2e test-linux-e2e

debug:
	zig build

release:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf zig-out .zig-cache

update-ghostty:
	zig fetch --save=ghostty https://github.com/ghostty-org/ghostty/archive/main.tar.gz

# macOS UI 端到端测试:按本机架构构建 .app + wisptermctl,确保 pytest 在位,再跑。
# 固定用 /usr/bin/python3(其 user-site 挂着 PyObjC)。需已授予运行终端"辅助功能"权限。
MACOS_TARGET := $(shell uname -m | sed 's/arm64/aarch64/')-macos
test-macos-e2e:
	zig build -Dtarget=$(MACOS_TARGET) macos-app
	zig build -Dtarget=$(MACOS_TARGET) wisptermctl
	/usr/bin/python3 -m pytest --version >/dev/null 2>&1 || /usr/bin/python3 -m pip install --user pytest
	/usr/bin/python3 -m pytest tests/macos_e2e -v

# Linux UI 端到端测试:构建 Linux wispterm + wisptermctl,确保 pytest 在位,再跑。
# 需要 DISPLAY 已设置(X11/Wayland 会话)。xdotool 可选:控制通道测试在其缺失时也能跑。
test-linux-e2e:
	zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
	zig build -Dtarget=x86_64-linux-gnu wisptermctl
	python3 -m pytest --version >/dev/null 2>&1 || python3 -m pip install --user pytest
	python3 -m pytest tests/macos_e2e -v
