# Moonquakes - Minimal C ABI build
#
# Builds:
#   - Zig C API libraries via `zig build`
#   - minimal example executable
#
# Runtime is implemented in Zig.
# This Makefile provides a minimal C ABI smoke test.
#
# Run example:
#   LD_LIBRARY_PATH=zig-out/lib ./build/bin/minimal

CC      = cc
AR      = ar

CFLAGS  = -Wall -Wextra -O2 -fPIC -Iinclude

BUILD   = build
BINDIR  = $(BUILD)/bin

ZIG_LIBDIR = zig-out/lib
STATIC  = $(ZIG_LIBDIR)/libmoonquakes.a
SHARED  = $(ZIG_LIBDIR)/libmoonquakes.so

TARGET  = $(BINDIR)/minimal

all: $(TARGET)

$(BUILD):
	mkdir -p $(BUILD)

$(BINDIR):
	mkdir -p $(BINDIR)

# Build Zig libraries

zig-libs:
	zig build -Doptimize=ReleaseFast

# Example executable (links against shared library)

$(TARGET): examples/minimal.c zig-libs | $(BINDIR)
	$(CC) examples/minimal.c -Iinclude -L$(ZIG_LIBDIR) -lmoonquakes -o $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean zig-libs run

run: $(TARGET)
	LD_LIBRARY_PATH=$(ZIG_LIBDIR) ./$(TARGET)
