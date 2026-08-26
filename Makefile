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
SLINT_SOURCE := src/world/slint/native/src/lib.rs
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
	$(CC) $(CFLAGS) -shared -o $@ $(SOURCE) $(LDLIBS)

$(SLINT_LIBRARY): $(SLINT_MANIFEST) $(SLINT_LOCK) $(SLINT_SOURCE)
	@mkdir -p $(BUILD_DIR)
	CARGO_TARGET_DIR='$(SLINT_TARGET_DIR)' cargo build --locked --release --manifest-path $(SLINT_MANIFEST)
	cp '$(SLINT_TARGET_DIR)/release/libataxia_slint_native.so' $@

clean:
	rm -rf $(BUILD_DIR)
