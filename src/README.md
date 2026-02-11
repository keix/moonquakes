# Source Tree Overview

This directory contains the core implementation of Moonquakes.
The structure reflects the separation between compile-time,
runtime, and execution semantics.

## High-level layout

- `api/`
  C API constants and types for embedding.
  Provides Lua 5.4 compatible definitions with MQ_/MQL_ prefixes.

- `builtin/`
  Built-in standard libraries (e.g. `math`, `string`, `table`, `coroutine`).
  Implemented as native functions exposed to the language.

- `cli/`
  Command-line interface for the standalone interpreter.
  Separated from `main.zig` for testability.

- `compiler/`
  Grammar, lexical analysis, and bytecode generation.
  This layer is responsible for lowering Lua syntax into executable `Proto`s.

- `runtime/`
  Runtime value representation and garbage collection.
  This layer manages object lifetimes but does not execute code.

- `tests/`
  Semantic and regression tests.
  Tests are organized by language feature rather than implementation detail.

- `vm/`
  Register-based virtual machine that executes bytecode.
  Contains the main execution loop and error handling.

- `launcher.zig`
  Execution context setup (e.g. `arg` injection).
  Embedders can use this or build their own launcher.

- `main.zig`
  Entry point for the standalone interpreter.

- `moonquakes.zig`
  Public API facade that wires together compiler, VM, runtime, and builtins.

- `version.zig`
  Single source of truth for version information.
