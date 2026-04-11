# Moonquakes GC Architecture

## Overview

Moonquakes uses a non-moving mark-and-sweep garbage collector with stable
object addresses.

The collector is designed around three constraints:

- object pointers must remain stable
- VM and runtime roots must be explicit
- incremental and generational behavior must preserve Lua-visible semantics

The current collector supports:

- full collection
- incremental stepping
- generational mode with minor and major cycles
- weak tables
- deferred `__gc` finalization
- write barriers through centralized mutation helpers

## Core Components

### GC State

The main collector state lives in [`src/runtime/gc/state.zig`](../src/runtime/gc/state.zig).

```zig
pub const GC = struct {
    allocator: std.mem.Allocator,
    objects: ?*GCObject,
    strings: std.StringHashMap(*StringObject),

    bytes_allocated: usize,
    next_gc: usize,

    root_providers: std.ArrayListUnmanaged(RootProvider),
    finalizer_queue: std.ArrayListUnmanaged(FinalizerItem),
    remembered_set: std.ArrayListUnmanaged(*GCObject),
    weak_tables: std.ArrayListUnmanaged(*TableObject),

    mode: GcMode,
    current_cycle_kind: GcCycleKind,
    gc_state: GCState,

    current_mark: bool,
    gray_list: ?*GCObject,
    sweep_cursor: ?*GCObject,
    sweep_prev: ?*GCObject,
}
```

Important fields:

- `objects`: intrusive linked list of all GC-managed objects
- `strings`: intern table for string deduplication
- `root_providers`: runtime, VM, and tests register roots here
- `finalizer_queue`: deferred `__gc` work kept alive across cycles
- `remembered_set`: old tables that may reference young objects
- `weak_tables`: weak tables discovered during marking
- `current_mark`: flip-bit used to avoid O(n) mark clearing

### Object Model

All collectable objects share a common header defined in
[`src/runtime/gc/object.zig`](../src/runtime/gc/object.zig).

The collector currently manages:

- strings
- tables
- Lua closures
- native closures
- upvalues
- protos
- userdata
- threads
- file objects

The collector is non-moving, so objects are never relocated after allocation.

## Root Model

Moonquakes does not scan arbitrary memory.
Reachability begins from explicit root providers.

### Root Providers

`RootProvider` is the GC-facing interface for components that own roots.

Typical providers are:

- runtime state
- active VM instances
- test harnesses

Each provider exposes a single `markRoots(gc)` callback.

### Runtime Roots

The runtime contributes process-level roots such as:

- globals
- registry
- main thread
- current thread
- shared metatables
- interned metamethod key strings

### VM Roots

The VM contributes execution roots such as:

- stack values up to `vm.top`
- active call frames
- open upvalues
- error state
- traceback snapshots
- temporary GC roots

This boundary is important:

- values above `vm.top` do not keep objects alive
- inactive frames do not keep objects alive
- closed upvalues stop pointing at the thread stack

## Collection Model

The collector uses a simple state machine:

```text
idle -> mark -> sweep -> idle
```

This is implemented in [`src/runtime/gc/state.zig`](../src/runtime/gc/state.zig)
and the phase logic lives in:

- [`src/runtime/gc/mark.zig`](../src/runtime/gc/mark.zig)
- [`src/runtime/gc/sweep.zig`](../src/runtime/gc/sweep.zig)

### Mark Phase

Marking starts from roots and uses a gray list.

Color model:

- white: not marked in the current cycle
- gray: marked, children not yet scanned
- black: marked, children already scanned

`markGray()` marks an object and pushes it onto the gray list.
`propagateOne()` pops one gray object and scans its children.

The collector uses a flip-mark scheme:

- objects are considered marked when `obj.mark_bit == current_mark`
- starting a new cycle flips `current_mark`
- this avoids clearing all mark bits before each collection

### Sweep Phase

Sweep walks the intrusive object list and frees white objects that participate
in the current cycle.

Incremental sweep uses:

- `sweep_cursor`
- `sweep_prev`

to continue freeing across multiple API steps.

At the end of sweep:

- surviving objects age according to the cycle kind
- thresholds are recomputed
- minor cycles prune the remembered set

## Incremental Operation

`collectgarbage("step", n)` and the internal step path advance the GC state
machine instead of always forcing a full collection.

The current implementation supports:

- starting a cycle from `idle`
- draining mark work incrementally
- finishing mark atomically
- sweeping incrementally

The atomic part of mark still includes:

- draining remaining gray objects
- ephemeron propagation
- finalizer enqueue
- weak table cleanup preparation

This keeps semantics simple while still allowing stepped progress.

## Generational Mode

Generational mode is implemented with two cycle kinds:

- `minor`
- `major`

### Aging

Objects move through generations:

- `young`
- `survival`
- `old`

Minor cycles advance young survivors toward old.
Major cycles rescan the whole heap and normalize survivors to old.

### Minor Sources

Minor cycles do not rescan the entire old heap.

The current policy is:

- old tables are tracked through `remembered_set`
- several non-table old container kinds are still traced directly

This keeps the implementation conservative while allowing old-table writes to
avoid full old-heap rescans.

### Remembered Set

The remembered set tracks old tables that may reference young objects.

This is maintained by GC mutation helpers:

- when an old table gains a young key, young value, or young metatable, it is remembered
- when a mutation removes all young references from that table, it is forgotten immediately
- minor sweep also prunes remembered tables that no longer contain young references

This gives Moonquakes an explicit old-to-young source boundary without relying
on ad hoc table scans elsewhere in the VM.

## Write Barrier and Mutation Boundary

All GC-visible writes go through mutation helpers in
[`src/runtime/gc/mutation.zig`](../src/runtime/gc/mutation.zig).

Examples:

- `gc.tableSet(...)`
- `gc.tableSetMetatable(...)`
- `gc.userdataSetMetatable(...)`
- `gc.upvalueSet(...)`
- `gc.fileSetMetatable(...)`
- `gc.fileSetStringRef(...)`
- `gc.threadSetEntryFunc(...)`

This rule matters for two reasons:

- incremental marking must not leave a black object pointing at a white child
- generational mode must remember old containers that gain young references

Moonquakes uses a backward barrier:

- if a black parent starts referencing a white child, the parent is pushed back to gray
- in generational mode, old parents that gain young references are remembered

The working rule is simple:

All GC-visible writes must go through `gc` mutation helpers.

## Weak Tables

Weak table semantics are implemented in
[`src/runtime/gc/weak.zig`](../src/runtime/gc/weak.zig).

Supported modes:

- weak keys
- weak values
- weak both

Behavior:

- weak-value tables do not keep values alive
- weak-key tables behave as ephemerons
- cached iteration keys are cleared for weak tables so they do not retain dead keys

During cleanup:

- dead weak entries are removed after collection
- empty weak tables release oversized backing storage

Generational behavior is conservative:

- minor cycles must not treat old white objects as dead if they did not participate in the current cycle

## Finalizers

Deferred finalization is implemented in
[`src/runtime/gc/finalizer.zig`](../src/runtime/gc/finalizer.zig).

The GC is responsible for:

- finding unreachable objects with `__gc`
- enqueueing `(function, object)` pairs
- keeping queued items alive until execution

The VM is responsible for:

- draining the queue at safe execution boundaries
- executing the finalizer function
- reporting finalizer errors

Important semantics:

- queued finalizers are treated as roots
- minor cycles enqueue only objects that participate in the current cycle
- unreachable old finalizable objects wait for a major cycle

## Memory Accounting

Moonquakes uses a tracking allocator to keep `bytes_allocated` close to actual
runtime usage.

This accounting includes:

- object bodies
- table internal storage
- string interned payloads
- closure and proto arrays

The next threshold is computed from the surviving heap size and
`gc_multiplier`, with a floor at `gc_min_threshold`.

## Validation

GC behavior is currently validated through:

- `zig build test`
- `make test`
- `passing/all.lua`
- direct GC tests in [`src/tests/gc.zig`](../src/tests/gc.zig)

The GC test suite covers:

- barrier invariants
- incremental stepping
- generational aging
- remembered-set behavior
- weak table cleanup
- finalizer queue behavior

## Current Status

The current implementation is suitable as the `v0.4.0` baseline:

- collector correctness is covered by direct tests and Lua test suites
- incremental and generational modes are implemented
- mutation boundaries are explicit

Work still worth revisiting later:

- non-table old container policy in minor cycles
- remembered-set scope beyond old tables
- further performance tuning of minor collections
