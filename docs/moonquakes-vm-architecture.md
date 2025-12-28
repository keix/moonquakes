# Moonquakes VM Architecture

## Overview

The Moonquakes Virtual Machine implements a register-based execution model similar to Lua 5.4+. It manages execution state through call stacks, native function dispatch, and register allocation.

## Core Components

### VM Structure

```zig
pub const VM = struct {
    stack: [256]TValue,           // Value stack
    stack_last: u32,              // Stack boundary
    top: u32,                     // Current stack top
    base: u32,                    // Current frame base
    ci: ?*CallInfo,               // Current call info
    base_ci: CallInfo,            // Base call frame
    callstack: [20]CallInfo,      // Call stack (max 20 nested calls)
    callstack_size: u8,           // Current call stack depth
    globals: *Table,              // Global environment
    allocator: std.mem.Allocator, // Memory allocator
}
```

### CallInfo Structure

`CallInfo` represents a function call frame in the call stack:

```zig
pub const CallInfo = struct {
    func: *const Proto,                   // Function prototype
    pc: [*]const Instruction,             // Program counter
    base: u32,                            // Register frame base
    ret_base: u32,                        // Return value destination
    savedpc: ?[*]const Instruction,       // Saved PC for yields
    nresults: i16,                        // Expected return count (-1 = multiple)
    previous: ?*CallInfo,                 // Previous call frame
};
```

#### CallInfo Fields Explained

- **func**: Points to the function prototype being executed
- **pc**: Current instruction pointer within the function
- **base**: Base register index for this function's local variables
- **ret_base**: Where to place return values in the caller's register space
- **savedpc**: Saved program counter (used for coroutines/yields)
- **nresults**: Number of expected return values (-1 = variadic)
- **previous**: Linked list pointer to previous call frame

### Call Stack Management

#### Pushing a Call Frame

```zig
pub fn pushCallInfo(self: *VM, func: *const Proto, base: u32, ret_base: u32, nresults: i16) !*CallInfo
```

1. Checks for stack overflow (max 20 nested calls)
2. Initializes new CallInfo structure
3. Links to previous frame
4. Updates VM state

#### Function Call Execution

1. **Native Functions**: Dispatched through `builtin.invoke()`
2. **Lua Functions**: Execute bytecode instructions
3. **Return Handling**: Restore previous call frame state

## Native Function Dispatch

### Dispatch Flow

```text
VM.execute() 
    → VM.callNative()
        → builtin.invoke()
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
fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (builtin.invoke(id, self, func_reg, nargs, nresults)) {
        // Builtin handled successfully
        return;
    } else |err| switch (err) {
        error.PrintNotImplementedInBuiltin => {
            // Fallback to VM implementation
            try self.nativePrint(func_reg, nargs, nresults);
        },
        else => return err,
    }
}
```

## Register Management

### Register Allocation

- Registers 0-3: Reserved for loop variables and special cases
- Register 4+: Available for general allocation
- Each function call gets its own register window

### Value Stack Layout

```text
Stack:  [global_base] [func1_locals] [func2_locals] [current_frame]
Regs:   0..n          base1..top1    base2..top2    base3..top3
```

## Instruction Execution

### Main Execution Loop

```zig
pub fn execute(self: *VM, proto: *const Proto) !void
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

Initialized by `builtin.initGlobalEnvironment()`:
- Creates global table
- Registers builtin functions
- Sets up io table and functions

### Cleanup

```zig
pub fn deinit(self: *VM) void
```
- Cleans up io table
- Destroys global environment
- Frees allocated memory

## Performance Considerations

### Call Stack Limits
- Maximum 20 nested function calls
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

