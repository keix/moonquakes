# Moonquakes - Minimal C ABI build
#
# Builds:
#   - libmoonquakes.a
#   - libmoonquakes.so.0.1.0 (shared library)
#   - minimal example executable
#
# Runtime is implemented in Zig.
# This Makefile provides a minimal C ABI smoke test.
#
# Run example:
#   LD_LIBRARY_PATH=build/lib ./build/bin/minimal

CC      = cc
AR      = ar

CFLAGS  = -Wall -Wextra -O2 -fPIC -Iinclude
LDFLAGS = -shared

VERSION = 0.1.0
SOMAJOR = 0

BUILD   = build
LIBDIR  = $(BUILD)/lib
BINDIR  = $(BUILD)/bin

STATIC  = $(LIBDIR)/libmoonquakes.a
SHARED  = $(LIBDIR)/libmoonquakes.so.$(VERSION)
SONAME  = libmoonquakes.so.$(SOMAJOR)

TARGET  = $(BINDIR)/minimal

C_SRC   = src/api/c/moonquakes.c
C_OBJ   = $(BUILD)/moonquakes.o

all: $(STATIC) $(SHARED) $(TARGET)

$(BUILD):
	mkdir -p $(BUILD)

$(LIBDIR):
	mkdir -p $(LIBDIR)

$(BINDIR):
	mkdir -p $(BINDIR)

# Compile position-independent object

$(C_OBJ): $(C_SRC) | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# Static library

$(STATIC): $(C_OBJ) | $(LIBDIR)
	$(AR) rcs $@ $^

# Shared library with SONAME

$(SHARED): $(C_OBJ) | $(LIBDIR)
	$(CC) $(LDFLAGS) -Wl,-soname,$(SONAME) -o $@ $^
	ln -sf libmoonquakes.so.$(VERSION) $(LIBDIR)/$(SONAME)
	ln -sf $(SONAME) $(LIBDIR)/libmoonquakes.so

# Example executable (links against shared library)

$(TARGET): examples/minimal.c $(SHARED) | $(BINDIR)
	$(CC) examples/minimal.c -Iinclude -L$(LIBDIR) -lmoonquakes -o $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean