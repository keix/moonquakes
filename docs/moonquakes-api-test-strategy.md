# Moonquakes API Test Strategy

This document describes the approach for introducing `src/tests/api` as the
stable test surface for Moonquakes builtin libraries.

The immediate goal is to freeze the observable behavior of builtin functions
now that the upstream Lua 5.4 test suite is passing end-to-end.

## Goals

- Freeze the Lua-visible contract of builtin libraries
- Add focused regression coverage for edge cases not isolated well by `passing/`
- Keep tests resilient to internal refactors
- Make compatibility progress measurable per builtin surface

## Non-Goals

- Re-test the entire upstream Lua test suite inside Zig unit tests
- Lock in internal implementation details
- Require byte-for-byte matching for every error string or debug artifact
- Replace VM opcode tests already covered in `src/tests`

## Why `src/tests/api`

The current test layout is strong at two levels:

- VM and compiler mechanics (`src/tests`)
- Whole-system Lua compatibility (`passing/`)

What is still missing is a stable middle layer:

- builtin-by-builtin black-box contract tests

This layer should answer questions such as:

- What does `assert` return on success?
- How does `pcall` shape its results?
- What part of `debug.getinfo` is guaranteed today?
- What error class and message shape should `loadfile` produce?

## Core Principle

API tests should validate behavior as Lua code sees it.

That means:

- prefer executing Lua chunks over calling Zig builtin helpers directly
- assert returned Lua values, visible side effects, and Lua-level exceptions
- avoid coupling tests to private helper functions or allocation details

This keeps the suite stable even if the internal implementation changes.

## Test Model

Each API test should usually follow this shape:

1. Build a fresh `Runtime` and `VM`
2. Compile a small Lua chunk
3. Execute it through the normal runtime path
4. Assert one of:
   - return values
   - modified globals or tables
   - coroutine state transitions
   - Lua exception type and message fragment

Tests should prefer short Lua programs that express one contract each.

## Directory Layout

Recommended structure:

```text
src/tests/api/
  test_api_utils.zig
  global.zig
  string.zig
  table.zig
  math.zig
  coroutine.zig
  debug.zig
  io.zig
  os.zig
  utf8.zig
  modules.zig
```

### Utility Layer

`test_api_utils.zig` should provide helpers such as:

- compile and execute a Lua chunk
- compile and expect a Lua exception
- fetch global values after execution
- compare multiple returned Lua values
- assert message fragments instead of full-string equality

The utility layer should be intentionally small.
The tests should remain readable without hiding too much logic.

## Test Categories

Each builtin module should be covered through three categories.

### 1. Success Path

Examples:

- `assert` returns all arguments when the first one is truthy
- `tonumber("10")` returns `10`
- `table.unpack` returns the expected range
- `coroutine.status` reports expected lifecycle states

### 2. Error Contract

Examples:

- wrong argument type
- missing argument
- unsupported mode
- invalid coroutine state

Assertions should focus on:

- whether execution raises a Lua-visible exception
- whether the message contains the expected semantic fragment

Prefer substring checks over full-string equality unless the wording is meant to
be frozen exactly.

### 3. Known Partial Compatibility

Some builtin surfaces are intentionally incomplete.
These should still be documented in tests.

Examples:

- partial `debug.getinfo` coverage
- incomplete hook compatibility
- unimplemented `package` behavior

Use explicit test names that make the current boundary visible, rather than
silently skipping behavior.

## Priority Order

Recommended implementation order:

1. `global`
2. `modules`
3. `debug`
4. `coroutine`
5. `string`
6. `table`
7. `math`
8. `utf8`
9. `io`
10. `os`

Rationale:

- `global`, `modules`, `debug`, and `coroutine` define the most fragile runtime
  contracts
- they are also the easiest places for future regressions to appear without
  immediately breaking the upstream aggregate suite

## What to Freeze

The suite should freeze:

- result counts and ordering
- truthy/falsey behavior
- visible side effects on `_G`, tables, and threads
- Lua-visible error vs non-error behavior
- stable message fragments where users depend on them

The suite should not freeze:

- internal helper names
- exact internal stack layout
- memory allocation behavior
- implementation-specific debug internals unless intentionally exposed

## Relationship to Existing Tests

`src/tests`

- keeps low-level VM, compiler, and opcode coverage
- may still directly inspect registers and internal state

`src/tests/api`

- covers Lua-visible builtin behavior
- should treat the runtime as a black box

`passing/`

- remains the aggregate compatibility suite
- validates reference-style real-world behavior across the whole system

These three layers should complement each other rather than duplicate each
other.

## Recommended Conventions

### Naming

Use test names that read like API guarantees:

- `global.assert returns all arguments on success`
- `global.pcall returns false and message on runtime error`
- `debug.getinfo exposes current line for Lua closures`

### Scope

Keep one contract per test when possible.

Avoid very large mixed-behavior tests such as:

- checking successful return values
- checking message text
- checking side effects
- checking stack behavior

all inside one case unless the behavior is inseparable.

### Error Assertions

Prefer:

- `error.LuaException`
- plus a message fragment assertion

Do not depend on raw internal Zig errors unless the API is intentionally
specified to expose them directly.

## First Milestone

The first milestone should be small and concrete:

- create `src/tests/api/`
- add `test_api_utils.zig`
- add `global.zig`
- wire it into `src/test.zig`

`global.zig` should cover:

- `assert`
- `error`
- `pcall`
- `xpcall`
- `type`
- `tostring`
- `tonumber`
- `load`
- `loadfile`
- `dofile`
- `warn`

This single module will establish the style for the rest of the API suite.

## Success Criteria

The strategy is working if:

- builtin regressions are caught by focused tests before they reach `passing/`
- implementation refactors rarely require mass test rewrites
- the project can describe compatibility per builtin module, not only globally
- API behavior becomes intentionally frozen rather than incidentally preserved

## Summary

`src/tests/api` should become the frozen contract layer between low-level VM
tests and the upstream aggregate Lua suite.

It should be:

- black-box
- builtin-oriented
- small and explicit
- stable under internal refactoring

That makes it the right place to lock in builtin behavior for the v0.2 line and
beyond.
