# API Freeze

`src/tests/api` is the black-box API contract layer for Moonquakes.

This suite exists to freeze Lua-visible behavior for builtin libraries and core
runtime surfaces now that the upstream Lua 5.4 aggregate suite passes
end-to-end.

The purpose of this directory is not to duplicate opcode tests or the upstream
Lua tests. Its purpose is to define the behavior that must remain stable even
if the VM, compiler, table layout, call machinery, allocator behavior, or
optimization strategy changes.

## What This Suite Protects

The tests in this directory protect behavior that users can observe directly
from Lua code.

That includes:

- builtin library semantics
- result arity and return ordering
- truthiness and nil behavior
- metatable dispatch boundaries
- numeric conversion and equality behavior
- iteration contracts (`next`, `pairs`, `ipairs`)
- protected-call and traceback behavior
- module loading and loader caching behavior
- file and OS surface behavior that is intentionally exposed
- GC control surface behavior

This layer is especially important for work planned after `v0.3.0`.

`v0.4.0` is expected to introduce VM and runtime optimizations. Those changes
must not alter behavior covered by this suite. If an optimization changes a
result that these tests consider stable, the optimization is wrong or the API
contract must be updated deliberately and explicitly.

## What "Frozen" Means

For Moonquakes, "frozen" means:

- behavior covered by this suite is treated as a compatibility boundary
- internal refactors are allowed
- optimization is allowed
- representational changes are allowed
- observable Lua behavior covered here must remain stable

This is a behavior freeze, not an implementation freeze.

The VM may change substantially as long as the contracts asserted here still
hold.

## What These Tests Must Assert

API tests should assert only Lua-visible behavior.

Preferred assertions:

- returned Lua values
- number and ordering of returned values
- visible mutation of tables, globals, threads, and files
- Lua-visible errors versus successful execution
- stable message fragments when wording matters semantically

Tests in this directory should usually compile and execute small Lua chunks
through the normal runtime path instead of calling internal Zig helpers
directly.

That requirement is intentional. These tests are supposed to validate the
runtime as users experience it, not as internal helpers are currently arranged.

## What These Tests Should Avoid Freezing

This suite should avoid locking down details that do not represent a deliberate
user-facing contract.

Unless explicitly intended, do not freeze:

- internal helper names
- register layout
- stack slot placement
- GC timing details
- allocation patterns
- object addresses
- exact traceback formatting in every character position
- exact full error strings when only the semantic content matters

For error messages and tracebacks, prefer asserting meaningful substrings and
shape rather than byte-for-byte equality, unless exact wording is intentionally
part of the contract.

## Current Freeze Surface

As of the current `v0.3.0` API-freeze push, this directory covers:

- `global`
- `modules`
- `debug`
- `coroutine`
- `string`
- `table`
- `math`
- `utf8`
- `io`
- `os`
- `metatable`
- `numeric`
- `iteration`
- `error`
- `gc`

Taken together, these tests define the current frozen behavior for:

- core builtin functions
- metatable routing and raw-access boundaries
- value conversion and numeric semantics
- iteration mechanics
- protected-call and traceback contracts
- module and chunk loading behavior
- host-facing `io`, `os`, and GC control APIs

## Areas Still Outside the Freeze Boundary

This suite does not yet claim that every Lua 5.4 edge case is frozen.

The following remain partially covered or intentionally outside the current
freeze boundary:

- weak table semantics
- full `package` compatibility beyond currently tested behavior
- complete debug metadata compatibility
- every traceback formatting detail
- host/platform-specific edge cases not yet modeled here
- the future public C API

These areas may still evolve before they are explicitly frozen.

The most obvious currently under-specified surfaces are:

- advanced `package` details such as `searchpath`, `loadlib`, and remaining path semantics
- advanced `debug` behavior around locals, userdata, and interactive helpers
- advanced `string` behavior such as formatting, iterators, and binary pack/unpack helpers
- host-sensitive `io` and `os` details that need careful black-box coverage

When these areas are expanded, they should be added to the existing library
files where possible instead of fragmenting the directory into many narrowly
scoped files. Cross-cutting areas such as `metatable`, `numeric`, `iteration`,
`error`, and `gc` remain the main exception to that rule.

## Relationship to Other Test Layers

Moonquakes now has three complementary test layers:

`src/tests`

- low-level VM, compiler, and runtime tests
- may inspect implementation-facing behavior directly

`src/tests/api`

- black-box builtin and runtime contract tests
- defines the compatibility boundary for Lua-visible behavior

`passing/`

- aggregate upstream-style compatibility suite
- validates whole-system behavior against the official Lua tests

These layers serve different purposes. They should reinforce each other, not
collapse into one another.

## Rules For Future Changes

When changing builtin behavior or VM/runtime semantics:

1. Update or add an API test if the behavior is user-visible.
2. Treat failures in this directory as compatibility regressions by default.
3. Do not weaken assertions just to make an optimization pass.
4. If a contract must change intentionally, update this README or the relevant
   strategy document to make the change explicit.

If a future optimization breaks `src/tests/api`, that is a signal that the
optimization needs to be corrected or the contract needs an intentional
compatibility decision.

## Style Guidance For New API Tests

New tests in this directory should:

- focus on one contract at a time when possible
- use short Lua chunks
- prefer semantic assertions over incidental details
- avoid depending on unrelated behavior in the same test
- document partial compatibility explicitly in the test name when needed

Test names should read like guarantees, for example:

- `metatable __index function dispatches missing keys`
- `numeric rawlen bypasses __len and rawequal ignores metamethods`
- `error xpcall reports handler failures with canonical message`

That naming style is deliberate. These tests are meant to describe the frozen
surface, not just the implementation being exercised today.
