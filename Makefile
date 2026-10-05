# Ataxia native libraries, helpers and test entry points.
#
# The glue shared object contains only direct wlroots/libwayland ABI helpers
# that cannot be represented safely with portable CFFI declarations.

PREFIX ?= $(HOME)/.local/ataxia
PKG_CONFIG ?= pkg-config
PKG_CONFIG_PATH := $(PREFIX)/lib/pkgconfig:$(PREFIX)/share/pkgconfig:$(PKG_CONFIG_PATH)
CMAKE ?= cmake
BUILD_DIR := build
GLUE := $(BUILD_DIR)/libataxia-wlr-glue.so
SOURCE := native/ataxia-wlr-glue.c native/ataxia-clipboard.c native/ataxia-xwayland.c
HEADER := native/ataxia-wlr-glue.h

CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -fvisibility=hidden -Wall -Wextra -Wpedantic
CFLAGS += -DWLR_USE_UNSTABLE
CFLAGS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --cflags wlroots-0.20 wayland-server xkbcommon)
LDLIBS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --libs wlroots-0.20 wayland-server xkbcommon)

# Test commands: Lisp scripts run against the libraries built here, and World
# scripts additionally render with GLES on the headless backend.
RUN_ENV := LD_LIBRARY_PATH='$(abspath $(BUILD_DIR)):$(PREFIX)/lib:$(LD_LIBRARY_PATH)'
SBCL_SCRIPT := sbcl --noinform --disable-debugger --eval '(sb-int:set-floating-point-modes :traps nil)' --script
LISP_TEST := $(RUN_ENV) $(SBCL_SCRIPT)
WORLD_TEST := WLR_RENDERER=gles2 $(LISP_TEST)
BUS_WORLD_TEST := WLR_RENDERER=gles2 $(RUN_ENV) dbus-run-session -- $(SBCL_SCRIPT)

.PHONY: all clean
all: $(BUILD_DIR)/libataxia-wlr-client.so $(BUILD_DIR)/libataxia-wlr-drag.so $(GLUE) $(BUILD_DIR)/libataxia-screencast.so web

clean:
	rm -rf $(BUILD_DIR)

$(BUILD_DIR)/libataxia-wlr-client.so: native/ataxia-client.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

$(BUILD_DIR)/libataxia-wlr-drag.so: native/ataxia-drag.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

$(GLUE): $(SOURCE) $(HEADER)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@.pending $(SOURCE) $(LDLIBS)
	mv $@.pending $@

# Prefer distro development packages. A locally extracted SDK can also live in
# build/portal-deps; this does not change the compositor's runtime search path.
PIPEWIRE_CFLAGS = $(shell pkg-config --cflags libpipewire-0.3 2>/dev/null || echo '-Ibuild/portal-deps/usr/include/pipewire-0.3 -Ibuild/portal-deps/usr/include/spa-0.2')
PIPEWIRE_LIBS = $(shell pkg-config --libs libpipewire-0.3 2>/dev/null || echo '-l:libpipewire-0.3.so.0')
$(BUILD_DIR)/libataxia-screencast.so: src/world/screencast/native.c
	@mkdir -p $(BUILD_DIR)
	$(CC) -O2 -g -std=gnu11 -fPIC -fvisibility=hidden -Wall -Wextra -shared -o $@.pending $< $(PIPEWIRE_CFLAGS) $(PIPEWIRE_LIBS) $$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0)
	mv $@.pending $@

$(BUILD_DIR)/libataxia-synthetic-input.so: src/world/synthetic-input/native.c
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

$(BUILD_DIR)/libataxia-cua.so: src/world/computer-use/native/bridge.c
	$(CC) $(CFLAGS) -shared -o $@.pending $< $(LDLIBS)
	mv $@.pending $@

# Browser UI for the desktop shell, panels and pages; the Kernel stays independent.
# Override CEF_ROOT to use a compatible CEF SDK on another architecture.
CEF_ROOT ?= $(abspath $(BUILD_DIR)/cef/cef_binary_154.0.32+g682c378+chromium-154.0.8037.58_linux64_minimal)
.PHONY: web web-example
web:
	@test -f '$(CEF_ROOT)/include/cef_app.h' || ./scripts/fetch-cef
	$(CMAKE) -S src/world/web/native -B $(BUILD_DIR)/web-native -G Ninja -DCMAKE_BUILD_TYPE=Release -DCEF_ROOT='$(CEF_ROOT)'
	$(CMAKE) --build $(BUILD_DIR)/web-native --parallel 4
	cp $(BUILD_DIR)/web-native/libataxia-web-native.so $(BUILD_DIR)/libataxia-web-native.so.pending
	mv $(BUILD_DIR)/libataxia-web-native.so.pending $(BUILD_DIR)/libataxia-web-native.so
web-example:
	npm ci --prefix examples/web-ui --ignore-scripts
	npm run build --prefix examples/web-ui

# Stage World and its TypeScript director SDK; nothing else depends on either.
.PHONY: stage
stage:
	npm ci --prefix sdk/stage --ignore-scripts
	npm run build --prefix sdk/stage

.PHONY: computer-use
computer-use: all $(BUILD_DIR)/libataxia-synthetic-input.so $(BUILD_DIR)/libataxia-cua.so

# Test fixtures: native harnesses and small Wayland and X11 clients.
$(BUILD_DIR)/gesture-native-test: tests/gesture-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/gesture-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS)
$(BUILD_DIR)/damage-native-test: tests/damage-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/damage-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS) $$(pkg-config --libs pixman-1)
$(BUILD_DIR)/clipboard-native-test: tests/clipboard-native.c $(GLUE) $(HEADER)
	$(CC) $(CFLAGS) -I. -o $@ tests/clipboard-native.c -L$(BUILD_DIR) \
		-Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-wlr-glue $(LDLIBS)
$(BUILD_DIR)/cua-clipboard-native-test: tests/cua-clipboard-native.c $(BUILD_DIR)/libataxia-cua.so
	$(CC) $(CFLAGS) -o $@ $< -L$(BUILD_DIR) -Wl,-rpath,'$(abspath $(BUILD_DIR))' -lataxia-cua $(LDLIBS)
$(BUILD_DIR)/xdg-shell-client.h:
	wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $@
$(BUILD_DIR)/xdg-shell-client.c:
	wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $@
$(BUILD_DIR)/computer-use-client: tests/computer-use-client.c $(BUILD_DIR)/xdg-shell-client.h $(BUILD_DIR)/xdg-shell-client.c
	$(CC) -O2 -Wall -Wextra -I$(BUILD_DIR) -o $@ tests/computer-use-client.c $(BUILD_DIR)/xdg-shell-client.c $$(pkg-config --cflags --libs wayland-client xkbcommon)
$(BUILD_DIR)/xwayland-client: tests/xwayland-client.c
	$(CC) -O2 -Wall -Wextra -o $@ $< $$(pkg-config --cflags --libs x11)

.PHONY: test
test: all $(BUILD_DIR)/gesture-native-test
	$(RUN_ENV) sh tests/run

.PHONY: test-occlusion
test-occlusion: all $(BUILD_DIR)/damage-native-test
	$(RUN_ENV) ./$(BUILD_DIR)/damage-native-test
	$(WORLD_TEST) tests/occlusion-gles.lisp

.PHONY: test-view-shift-idle
test-view-shift-idle: all
	$(WORLD_TEST) tests/view-shift-idle.lisp

.PHONY: test-xwayland
test-xwayland: all $(BUILD_DIR)/xwayland-client $(BUILD_DIR)/libataxia-synthetic-input.so
	$(WORLD_TEST) tests/runtime-xwayland.lisp
	$(WORLD_TEST) tests/xwayland-world.lisp
	$(WORLD_TEST) tests/xwayland-contract.lisp

.PHONY: test-drag
test-drag: all $(BUILD_DIR)/computer-use-client $(BUILD_DIR)/libataxia-synthetic-input.so
	$(WORLD_TEST) tests/drag-world.lisp
	$(WORLD_TEST) tests/drag-placement-world.lisp

.PHONY: test-screencast
test-screencast: all $(BUILD_DIR)/computer-use-client
	$(BUS_WORLD_TEST) tests/screencast-world.lisp
	$(BUS_WORLD_TEST) tests/stage-screencast.lisp

# Public portal tests need xdg-desktop-portal, Python GI/GStreamer and PipeWire.
.PHONY: test-qol
test-qol: test-xwayland test-screencast test-drag
	$(WORLD_TEST) tests/qol-world.lisp

.PHONY: test-computer-use
test-computer-use: computer-use $(BUILD_DIR)/computer-use-client $(BUILD_DIR)/cua-clipboard-native-test
	$(RUN_ENV) ./$(BUILD_DIR)/cua-clipboard-native-test
	$(LISP_TEST) tests/computer-use-boundaries.lisp
	$(LISP_TEST) tests/computer-use-desktop.lisp
	$(WORLD_TEST) tests/computer-use-viewport-navigation.lisp
	$(LISP_TEST) tests/computer-use-json.lisp
	$(LISP_TEST) tests/computer-use-png.lisp
	$(WORLD_TEST) tests/computer-use-world.lisp
	$(WORLD_TEST) tests/computer-use-window.lisp
	$(WORLD_TEST) tests/computer-use-transforms.lisp
	$(WORLD_TEST) tests/computer-use-popups.lisp
	$(WORLD_TEST) tests/computer-use-lifecycle.lisp
	$(WORLD_TEST) tests/computer-use-clipboard.lisp
	$(WORLD_TEST) tests/computer-use-concurrent.lisp

.PHONY: test-assistant test-portability
test-assistant: test-portability $(BUILD_DIR)/computer-use-client
	$(LISP_TEST) tests/launcher-catalog.lisp
	$(LISP_TEST) tests/assistant-unit.lisp
	$(LISP_TEST) tests/assistant-scheduling.lisp
	$(LISP_TEST) tests/assistant-format.lisp
	$(WORLD_TEST) tests/assistant-service-lifecycle.lisp
	$(WORLD_TEST) tests/assistant-world.lisp
	$(WORLD_TEST) tests/assistant-launch-world.lisp
	$(WORLD_TEST) tests/assistant-voice-world.lisp
	$(WORLD_TEST) tests/assistant-lisp-world.lisp
	$(WORLD_TEST) tests/agent-sly-world.lisp
	$(WORLD_TEST) tests/assistant-idle-world.lisp
	$(WORLD_TEST) tests/assistant-approval-world.lisp
test-portability: computer-use
	$(LISP_TEST) tests/portable-desktop-host.lisp
	$(WORLD_TEST) tests/assistant-infinite-world.lisp

.PHONY: test-shell test-shell-backends
test-shell: all $(BUILD_DIR)/clipboard-native-test $(BUILD_DIR)/libataxia-synthetic-input.so $(BUILD_DIR)/computer-use-client
	$(RUN_ENV) ./$(BUILD_DIR)/clipboard-native-test
	$(LISP_TEST) tests/shell-bar-unit.lisp
	$(LISP_TEST) tests/shell-power-unit.lisp
	$(WORLD_TEST) tests/shell-controls-world.lisp
	$(WORLD_TEST) tests/shell-clipboard-client.lisp
	$(WORLD_TEST) tests/shell-workspaces-world.lisp
	$(WORLD_TEST) tests/shell-power-world.lisp
test-shell-backends:
	dbus-run-session -- $(SBCL_SCRIPT) tests/shell-mpris.lisp
	timeout 30s python3 tests/shell-audio-test.py

.PHONY: test-web test-web-shell test-web-ui
test-web: all web-example
	python3 tests/web-gles.py
	$(WORLD_TEST) tests/web-portable.lisp
	$(WORLD_TEST) tests/web-world.lisp
test-web-shell: all
	$(WORLD_TEST) tests/web-shell-startup.lisp
	$(WORLD_TEST) tests/web-shell-world.lisp
test-web-ui: all
	$(WORLD_TEST) tests/web-ui-world.lisp

.PHONY: test-stage
test-stage: all stage $(BUILD_DIR)/computer-use-client $(BUILD_DIR)/libataxia-synthetic-input.so
	npm test --prefix sdk/stage
	$(WORLD_TEST) tests/stage-world.lisp

.PHONY: benchmark-idle benchmark-desktop-idle
benchmark-idle: computer-use
	$(WORLD_TEST) tests/idle-performance.lisp
benchmark-desktop-idle: all $(BUILD_DIR)/computer-use-client $(BUILD_DIR)/xwayland-client
	$(BUS_WORLD_TEST) tests/desktop-idle.lisp
