# Moonquakes VM Architecture

## Overview

The Moonquakes Virtual Machine implements a register-based execution model similar to Lua 5.4+. It manages execution state through call stacks, native function dispatch, and register allocation.

## Core Components

### VM Structure

```zig
pub const VM = struct {
    stack: [256]TValue,        // Value stack
    top: u32,                  // Current stack top (GC scan extent)
    base: u32,                 // Current frame base
    ci: ?*CallInfo,            // Current call info
    base_ci: CallInfo,         // Base call frame
    callstack: [35]CallInfo,   // Call stack (vm.callstack.len)
    callstack_size: u8,        // Current call stack depth
    open_upvalues: ?*UpvalueObject,
    lua_error_value: TValue,   // Error object for LuaException

    // Yield state
    yield_base: u32,
    yield_count: u32,
    yield_ret_base: u32,
    yield_nresults: i32,       // -1 = variable results

    rt: *Runtime,              // Shared runtime (GC, globals, registry)
    thread: *ThreadObject,     // GC-managed thread object

    temp_roots: [8]TValue,
    temp_roots_count: u8,

    hook_func: ?*ClosureObject,
    hook_mask: u8,             // 1=call, 2=return, 4=line
    hook_count: u32,
}
```

### CallInfo Structure

`CallInfo` represents a function call frame in the call stack:

```zig
pub const CallInfo = struct {
    func: *const ProtoObject,       // Function prototype
    closure: ?*ClosureObject,       // Closure (null for main chunk)

    pc: [*]const Instruction,       // Program counter
    savedpc: ?[*]const Instruction, // Saved PC for yields

    base: u32,                      // Register frame base
    ret_base: u32,                  // Return value destination

    vararg_base: u32,               // Vararg base
    vararg_count: u32,              // Vararg count

    nresults: i16,                  // Expected return count (-1 = multiple)
    previous: ?*CallInfo,           // Previous call frame

    is_protected: bool,             // True if this is a pcall frame
    tbc_bitmap: u64,                // To-be-closed registers bitmap
};
```

#### CallInfo Fields Explained

- **func**: Points to the function prototype being executed
- **closure**: Closure for upvalue access (null for main chunk)
- **pc**: Current instruction pointer within the function
- **base**: Base register index for this function's local variables
- **ret_base**: Where to place return values in the caller's register space
- **savedpc**: Saved program counter (used for coroutines/yields)
- **vararg_base**: Stack base for varargs
- **vararg_count**: Number of vararg values
- **nresults**: Number of expected return values (-1 = variadic)
- **previous**: Linked list pointer to previous call frame
- **is_protected**: True if this is a pcall frame
- **tbc_bitmap**: Bitmap of to-be-closed registers

### Call Stack Management

#### Pushing a Call Frame

```zig
pub fn pushCallInfo(vm: *VM, func: *const ProtoObject, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16) !*CallInfo
```

1. Checks for stack overflow (max `vm.callstack.len` frames)
2. Initializes new CallInfo structure
3. Links to previous frame
4. Updates VM state

#### Function Call Execution

1. **Native Functions**: Dispatched through `builtin_dispatch.invoke()`
2. **Lua Functions**: Execute bytecode instructions
3. **Return Handling**: Restore previous call frame state

## Native Function Dispatch

### Dispatch Flow

```text
Mnemonics.execute()
    → VM.callNative()
        → builtin_dispatch.invoke()
            → specific implementation (string.zig, io.zig, etc.)
```

### Native Function Protocol

Native functions receive these parameters:
- `vm`: VM instance
- `func_reg`: Register containing the function
- `nargs`: Number of arguments
- `nresults`: Expected number of results

Arguments are located at `vm.stack[vm.base + func_reg + 1..]`

### Error Handling

```zig
pub fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
    try builtin_dispatch.invoke(id, self, func_reg, nargs, nresults);
}
```

## Register Management

### Register Allocation

- Registers are addressed relative to `base`
- Each function call gets its own register window

### Value Stack Layout

```text
Stack:  [global_base] [func1_locals] [func2_locals] [current_frame]
Regs:   0..n          base1..top1    base2..top2    base3..top3
```

## Instruction Execution

### Main Execution Loop

```zig
pub fn execute(vm: *VM, proto: *const ProtoObject) !ReturnValue
```

1. Set up initial call frame
2. Execute instructions until RETURN
3. Handle function calls (native and Lua)
4. Manage stack and register state

### Function Call Instructions

- **CALL**: Execute function call with specified arguments/results
- **Native dispatch**: Route to appropriate builtin implementation
- **Return handling**: Restore caller state and place results

## Memory Management

### Global Environment

Initialized by `Runtime.init()` via `builtin_dispatch.initGlobalEnvironment()`:
- Creates global and registry tables
- Registers builtin functions

### Finalizers (__gc)

Moonquakes queues `__gc` finalizers during GC, then executes them from the
currently running VM at safe points.

- **GC responsibility:** discover unreachable objects with `__gc` and enqueue
  them; keep queued objects and their `__gc` closures alive until execution.
- **VM responsibility:** drain the finalizer queue (Lua calls) at safe points
  such as the main execute loop or coroutine resume boundaries.
- **Executor selection:** the active VM is set as the finalizer executor based
  on `Runtime.current_thread`.

### Cleanup

```zig
pub fn deinit(self: *VM) void
```
- Main thread unregisters as a GC root provider
- VM memory is released (Runtime owns GC/globals/registry)

## Performance Considerations

### Call Stack Limits
- Maximum `vm.callstack.len` nested function calls (currently 35)
- Stack overflow protection
- Efficient frame allocation

### Register Optimization
- Direct register addressing
- Minimal copying between frames
- Efficient argument passing

## Integration Points

### Parser Integration
- Functions compiled to CALL instructions
- Native functions referenced by ID
- Register allocation coordinated

### Builtin System Integration  
- Unified dispatch mechanism
- Error propagation
- Global environment setup
