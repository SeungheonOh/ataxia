# Ataxia native glue build.
#
# The shared object contains only direct wlroots/libwayland ABI helpers that
# cannot be represented safely with portable CFFI declarations.

PREFIX ?= $(HOME)/.local/ataxia
PKG_CONFIG ?= pkg-config
PKG_CONFIG_PATH := $(PREFIX)/lib/pkgconfig:$(PREFIX)/share/pkgconfig:$(PKG_CONFIG_PATH)
BUILD_DIR := build
GLUE := $(BUILD_DIR)/libataxia-wlr-glue.so
SOURCE := native/ataxia-wlr-glue.c
HEADER := native/ataxia-wlr-glue.h
SLINT_MANIFEST := src/world/slint/native/Cargo.toml
SLINT_LOCK := src/world/slint/native/Cargo.lock
SLINT_SOURCE := $(wildcard src/world/slint/native/src/*.rs) src/world/slint/native/build.rs \
                src/world/slint/native/builtins.slint $(wildcard src/worlds/metaworld/*.slint) $(wildcard src/worlds/metaworld/icons/*.svg)
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
	CARGO_TARGET_DIR='$(SLINT_TARGET_DIR)' cargo build --locked --release --manifest-path $(SLINT_MANIFEST)
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
