# Ataxia native glue build.
#
# The shared object contains only direct wlroots/libwayland ABI helpers that
# cannot be represented safely with portable CFFI declarations.

PREFIX ?= $(HOME)/.local/ataxia
PKG_CONFIG ?= pkg-config
PKG_CONFIG_PATH := $(PREFIX)/lib/pkgconfig:$(PREFIX)/share/pkgconfig:$(PKG_CONFIG_PATH)
BUILD_DIR := build
GLUE := $(BUILD_DIR)/libataxia-wlr-glue.so
SOURCE := native/ataxia-wlr-glue.c native/ataxia-clipboard.c
HEADER := native/ataxia-wlr-glue.h
SLINT_MANIFEST := src/world/slint/native/Cargo.toml
SLINT_LOCK := src/world/slint/native/Cargo.lock
SLINT_SOURCE := $(wildcard src/world/slint/native/src/*.rs) src/world/slint/native/build.rs \
                $(wildcard src/worlds/metaworld/native/*) $(wildcard src/worlds/metaworld/*.slint) $(wildcard src/worlds/metaworld/icons/*.svg)
SLINT_TARGET_DIR := $(abspath $(BUILD_DIR)/slint-target)
SLINT_LIBRARY := $(BUILD_DIR)/libataxia-slint-native.so

CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -fvisibility=hidden -Wall -Wextra -Wpedantic
CFLAGS += -DWLR_USE_UNSTABLE
CFLAGS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --cflags wlroots-0.20 wayland-server xkbcommon)
LDLIBS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --libs wlroots-0.20 wayland-server xkbcommon)

.PHONY: all clean

all: $(GLUE) $(SLINT_LIBRARY)

$(GLUE): $(SOURCE) $(HEADER)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@.pending $(SOURCE) $(LDLIBS)
	mv $@.pending $@

$(SLINT_LIBRARY): $(SLINT_MANIFEST) $(SLINT_LOCK) $(SLINT_SOURCE)
	@mkdir -p $(BUILD_DIR)
	CARGO_TARGET_DIR='$(SLINT_TARGET_DIR)' cargo build --locked --release --features metaworld-controls --manifest-path $(SLINT_MANIFEST)
	cp '$(SLINT_TARGET_DIR)/release/libataxia_slint_native.so' $@.pending
	mv $@.pending $@

clean:
	rm -rf $(BUILD_DIR)

$(BUILD_DIR)/gesture-native-test: tests/gesture-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/gesture-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS)

.PHONY: test
test: all $(BUILD_DIR)/gesture-native-test
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sh tests/run

.PHONY: test-occlusion
$(BUILD_DIR)/damage-native-test: tests/damage-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/damage-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS) $$(pkg-config --libs pixman-1)

test-occlusion: all $(BUILD_DIR)/damage-native-test
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' ./$(BUILD_DIR)/damage-native-test
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/occlusion-gles.lisp

# Optional HTML/CSS UI engine. RmlUi 6.3 is pinned and verified by CMake.
CMAKE ?= cmake
RMLUI_BUILD := $(BUILD_DIR)/rmlui-native
RMLUI_LIBRARY := $(BUILD_DIR)/libataxia-rmlui-native.so
.PHONY: rmlui test-rmlui
rmlui: $(RMLUI_LIBRARY)
$(RMLUI_LIBRARY): $(wildcard src/world/rmlui/native/*)
	$(CMAKE) -S src/world/rmlui/native -B $(RMLUI_BUILD) -DCMAKE_BUILD_TYPE=Release
	$(CMAKE) --build $(RMLUI_BUILD) --parallel 4
	cp $(RMLUI_BUILD)/libataxia-rmlui-native.so $@.pending
	mv $@.pending $@

test-rmlui: all rmlui
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/rmlui.lisp
	python3 tests/rmlui-gles.py

.PHONY: test-rmlui-world
test-rmlui-world: all rmlui
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/rmlui-world.lisp

.PHONY: test-rmlui-status-bar test-rmlui-status-bar-world
test-rmlui-status-bar: all rmlui
	python3 tests/rmlui-status-bar-gles.py
test-rmlui-status-bar-world: all rmlui
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/rmlui-status-bar-world.lisp

.PHONY: test-rmlui-shell test-rmlui-shell-world
test-rmlui-shell: all rmlui
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/rmlui-shell-unit.lisp
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-power-unit.lisp
	python3 tests/rmlui-shell-gles.py
test-rmlui-shell-world: all rmlui
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/rmlui-shell-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-power-world.lisp

$(BUILD_DIR)/libataxia-synthetic-input.so: src/world/synthetic-input/native.c
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

$(BUILD_DIR)/libataxia-cua.so: src/world/computer-use/native/bridge.c
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

.PHONY: computer-use
computer-use: all rmlui $(BUILD_DIR)/libataxia-synthetic-input.so $(BUILD_DIR)/libataxia-cua.so

.PHONY: assistant
assistant: computer-use $(BUILD_DIR)/ataxia-rmlui-preview

.PHONY: benchmark-idle
benchmark-idle: assistant
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/idle-performance.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/slint-idle-world.lisp

$(BUILD_DIR)/ataxia-rmlui-preview: native/ataxia-rmlui-preview.cpp $(BUILD_DIR)/xdg-shell-client.h $(BUILD_DIR)/xdg-shell-client.c $(RMLUI_LIBRARY)
	$(CC) -fPIC -c -o $(BUILD_DIR)/preview-xdg-shell.o $(BUILD_DIR)/xdg-shell-client.c $$(pkg-config --cflags wayland-client)
	$(CXX) -std=c++17 -O2 -Wall -Wextra -I$(BUILD_DIR) -o $@.pending native/ataxia-rmlui-preview.cpp $(BUILD_DIR)/preview-xdg-shell.o -L$(BUILD_DIR) -Wl,-rpath,'$$ORIGIN' -lataxia-rmlui-native $$(pkg-config --cflags --libs wayland-client wayland-egl egl glesv2 xkbcommon expat)
	mv $@.pending $@

$(BUILD_DIR)/xdg-shell-client.h:
	wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $@
$(BUILD_DIR)/xdg-shell-client.c:
	wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $@
$(BUILD_DIR)/computer-use-client: tests/computer-use-client.c $(BUILD_DIR)/xdg-shell-client.h $(BUILD_DIR)/xdg-shell-client.c
	$(CC) -O2 -Wall -Wextra -I$(BUILD_DIR) -o $@ tests/computer-use-client.c $(BUILD_DIR)/xdg-shell-client.c $$(pkg-config --cflags --libs wayland-client xkbcommon)

.PHONY: test-computer-use
test-computer-use: computer-use $(BUILD_DIR)/computer-use-client
	sbcl --noinform --disable-debugger --script tests/computer-use-boundaries.lisp
	sbcl --noinform --disable-debugger --script tests/computer-use-desktop.lisp
	sbcl --noinform --disable-debugger --script tests/computer-use-json.lisp
	sbcl --noinform --disable-debugger --script tests/computer-use-png.lisp
	python3 tests/computer-use-gles.py
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-window.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-transforms.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-popups.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-lifecycle.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-clipboard.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-concurrent.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/computer-use-api.lisp

# The browser fixture uses only local disposable pages; production keeps Chromium sandboxed.
ATAXIA_CUA_NODE ?= $(shell command -v node 2>/dev/null || echo $(HOME)/.local/share/ataxia-cua/node/bin/node)
.PHONY: test-cua
$(BUILD_DIR)/cua-clipboard-native-test: tests/cua-clipboard-native.c $(BUILD_DIR)/libataxia-cua.so
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_DIR) -Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-cua $(LDLIBS)
test-cua: computer-use $(BUILD_DIR)/cua-clipboard-native-test
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' ./$(BUILD_DIR)/cua-clipboard-native-test
	$(ATAXIA_CUA_NODE) tests/cua-desktop-sdk.mjs
	$(ATAXIA_CUA_NODE) tests/cua-mcp.mjs
	$(ATAXIA_CUA_NODE) tests/cua-browser.mjs
	ATAXIA_CUA_NODE='$(ATAXIA_CUA_NODE)' WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' dbus-run-session -- sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/cua-world.lisp

.PHONY: test-assistant
test-assistant: assistant test-portability
	sbcl --noinform --disable-debugger --script tests/assistant-unit.lisp
	sbcl --noinform --disable-debugger --script tests/assistant-scheduling.lisp
	sbcl --noinform --disable-debugger --script tests/assistant-format.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-service-lifecycle.lisp
	python3 tests/assistant-gles.py
	python3 tests/assistant-notepad-gles.py
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-voice-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-preview-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-window-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-notepad-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-approval-world.lisp

.PHONY: test-portability
test-portability: assistant
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/portable-slint.lisp
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --script tests/portable-desktop-host.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/assistant-infinite-world.lisp

.PHONY: test-shell-controls test-shell-backends
$(BUILD_DIR)/clipboard-native-test: tests/clipboard-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/clipboard-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS)

test-shell-controls: all rmlui $(BUILD_DIR)/clipboard-native-test $(BUILD_DIR)/libataxia-synthetic-input.so $(BUILD_DIR)/computer-use-client
	LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' ./$(BUILD_DIR)/clipboard-native-test
	python3 tests/shell-controls-gles.py
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-controls-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-clipboard-client.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-workspaces-world.lisp
	WLR_RENDERER=gles2 LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)' sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-slint-clipboard.lisp

test-shell-backends:
	dbus-run-session -- sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/shell-mpris.lisp
	timeout 30s python3 tests/shell-audio-test.py
