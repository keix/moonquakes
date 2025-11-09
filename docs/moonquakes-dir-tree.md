# Moonquakes Project Structure
This document outlines the directory structure of the Moonquakes project —  a clean Zig implementation of the Lua 5.4 virtual machine and runtime.

It focuses only on directory layout and high-level responsibilities. Implementation details are intentionally omitted here.

```
moonquakes/
  build.zig
  src/
    core/                 # Core runtime types and memory model
      value.zig           # TValue, GC header, basic types (was lobject.c/h)
      string.zig          # String objects, interning (lstring.c/h)
      table.zig           # Table (array + hash part) implementation (ltable.c/h)
      state.zig           # Global state, lua_State equivalent (lstate.c/h)
      mem.zig             # Memory allocator layer (lmem.c/h)
      gc.zig              # Garbage collector basics (lgc.c/h) — minimal in Phase 1
      limits.zig          # Numerical and size limits (from llimits.h)
      vm_types.zig        # VM helper types (from lvm.h)
    compiler/             # Frontend (source → bytecode)
      zio.zig             # Input stream abstraction (lzio.c/h)
      token.zig           # Token definitions
      lexer.zig           # Lexer / tokenizer (llex.c/h)
      parser.zig          # Parser to Proto structure (lparser.c/h)
      codegen.zig         # Bytecode emitter / register allocation (lcode.c/h)
      opcodes.zig         # Opcode definitions and names (lopcodes.h / lopcodes.c)
      undump.zig          # Load binary chunk (.luac) (lundump.c/h)
      dump.zig            # Write binary chunk — optional, later (ldump.c)
    vm/                   # Virtual Machine (execution engine)
      vm.zig              # Core instruction dispatch loop (lvm.c)
      do.zig              # Call handling, error recovery (ldo.c/h)
      func.zig            # Proto, Closure, Upvalue handling (lfunc.c/h)
      tm.zig              # Tag methods / metatables (ltm.c/h) — later phase
    stdlib/               # Standard Lua libraries (minimal in Phase 1)
      base.zig            # print, type, pairs, etc. (lbaselib.c)
      strlib.zig          # string library (lstrlib.c) — later
      tablib.zig          # table library (ltablib.c) — later
      iolib.zig           # I/O library (liolib.c) — later
      mathlib.zig         # math library (lmathlib.c) — later
      corolib.zig         # coroutine library (lcorolib.c) — later
      utf8lib.zig         # UTF-8 library (lutf8lib.c) — later
      oslib.zig           # OS library (loslib.c) — later
      loadlib.zig         # package.loadlib / C library loader — later
    front/                # User-facing entrypoints
      repl.zig            # REPL / CLI main (lua.c)
      luac.zig            # Compiler CLI (luac.c) — optional
```
