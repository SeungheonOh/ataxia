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
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -fPIC -fvisibility=hidden -Wall -Wextra -Wpedantic
CFLAGS += -DWLR_USE_UNSTABLE
CFLAGS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --cflags wlroots-0.20 wayland-server)
LDLIBS += $(shell PKG_CONFIG_PATH='$(PKG_CONFIG_PATH)' $(PKG_CONFIG) --libs wlroots-0.20 wayland-server)

.PHONY: all clean

all: $(GLUE)

$(GLUE): $(SOURCE) $(HEADER)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -shared -o $@ $(SOURCE) $(LDLIBS)

clean:
	rm -rf $(BUILD_DIR)
