# Source Tree Overview

This directory contains the core implementation of Moonquakes.
The structure reflects the separation between compile-time,
runtime, and execution semantics.

## High-level layout

- `compiler/`  
  Grammar, lexical analysis, and bytecode generation.
  This layer is responsible for lowering Lua syntax into executable `Proto`s.

- `vm/`  
  Register-based virtual machine that executes bytecode.
  Contains the main execution loop and error handling.

- `runtime/`  
  Runtime value representation and garbage collection.
  This layer manages object lifetimes but does not execute code.

- `builtin/`  
  Built-in standard libraries (e.g. `math`, `string`, `table`, `coroutine`).
  Implemented as native functions exposed to the language.

- `tests/`  
  Semantic and regression tests.
  Tests are organized by language feature rather than implementation detail.

- `main.zig`  
  Entry point for the standalone interpreter.

- `moonquakes.zig`  
  Integration point that wires together compiler, VM, runtime, and builtins.
