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
PASSING_TESTS = $(sort $(wildcard passing/*.lua))

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

.PHONY: all clean zig-libs run test

run: $(TARGET)
	LD_LIBRARY_PATH=$(ZIG_LIBDIR) ./$(TARGET)

test: zig-libs
	@rc=0; \
	C_RESET=$$(printf '\033[0m'); \
	C_CYAN=$$(printf '\033[36m'); \
	C_GREEN=$$(printf '\033[32m'); \
	C_RED=$$(printf '\033[31m'); \
	cd passing && for f in *.lua; do \
		printf "%s===========================> %s%s\n" "$$C_CYAN" "$$f" "$$C_RESET"; \
		if ../zig-out/bin/moonquakes "$$f"; then \
			st=0; \
		else \
			st=$$?; \
			rc=1; \
		fi; \
		if [ "$$st" -eq 0 ]; then \
			printf "%sPASSED (%s)%s passing/%s\n" "$$C_GREEN" "$$st" "$$C_RESET" "$$f"; \
		else \
			printf "%sFAILED (%s)%s passing/%s\n" "$$C_RED" "$$st" "$$C_RESET" "$$f"; \
		fi; \
		echo; echo; \
	done; \
	exit $$rc
