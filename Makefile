# Moonquakes - Minimal C ABI build
#
# Builds:
#   - Zig C API libraries via `zig build`
#   - minimal example executable
#   - loadlib example shared object
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
LIBDIR  = $(BUILD)/lib

ZIG_LIBDIR = zig-out/lib
STATIC  = $(ZIG_LIBDIR)/libmoonquakes.a
SHARED  = $(ZIG_LIBDIR)/libmoonquakes.so

TARGET  = $(BINDIR)/minimal
LOADLIB_EXAMPLE = $(LIBDIR)/loadlib_addmul.so

all: $(TARGET)

$(BUILD):
	mkdir -p $(BUILD)

$(BINDIR):
	mkdir -p $(BINDIR)

$(LIBDIR):
	mkdir -p $(LIBDIR)

# Build Zig libraries

zig-libs:
	zig build -Doptimize=ReleaseFast

# Example executable (links against shared library)

$(TARGET): examples/minimal.c zig-libs $(LOADLIB_EXAMPLE) | $(BINDIR)
	$(CC) examples/minimal.c -Iinclude -L$(ZIG_LIBDIR) -lmoonquakes -o $@

# Example package.loadlib target.

$(LOADLIB_EXAMPLE): examples/loadlib_addmul.c zig-libs | $(LIBDIR)
	$(CC) $(CFLAGS) -shared examples/loadlib_addmul.c -o $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean zig-libs run test

run: $(TARGET)
	LD_LIBRARY_PATH=$(ZIG_LIBDIR) ./$(TARGET)

test: zig-libs
	zig build test --summary all

	@C_RESET=$$(printf '\033[0m'); \
	C_CYAN=$$(printf '\033[36m'); \
	C_GREEN=$$(printf '\033[32m'); \
	C_RED=$$(printf '\033[31m'); \
	printf "%smoonquakes> all.lua%s\n" "$$C_CYAN" "$$C_RESET"; \
	if cd passing && ../zig-out/bin/moonquakes all.lua >> /dev/null ; then \
		printf "%sPASSED%s passing/all.lua\n" "$$C_GREEN" "$$C_RESET"; \
	else \
		st=$$?; \
		printf "%sFAILED (%s)%s passing/all.lua\n" "$$C_RED" "$$st" "$$C_RESET"; \
		exit $$st; \
	fi
