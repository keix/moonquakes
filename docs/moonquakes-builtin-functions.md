# Moonquakes Builtin API Reference
This document describes the built-in functions provided by Moonquakes and their compatibility with standard Lua.

## Overview

Moonquakes provides a set of built-in functions that are available in the global environment. These functions are implemented as native functions in Zig and dispatched through a unified builtin system.

## Architecture

### Builtin Dispatch System

All builtin functions are managed through a centralized dispatch system:

```text
VM → builtin.invoke() → individual function implementations
```

**Key Files:**
- `src/builtin/dispatch.zig` - Main dispatch and environment initialization
- `src/builtin/string.zig` - String-related functions 
- `src/builtin/io.zig` - I/O functions

### Global Environment Initialization

The global environment is set up by `builtin.initGlobalEnvironment()`:

```lua
-- Available globals after initialization
tostring(value)  -- Convert value to string
io.write(...)    -- Write to stdout without newline
print(...)       -- Write to stdout with newline (legacy)
```

## Function Reference

### tostring(value)

Converts any Lua value to its string representation.

**Parameters:**
- `value` - Any Lua value

**Returns:**
- String representation of the value

**Examples:**
```lua
tostring(42)      -- "42" 
tostring("hello") -- "hello"
tostring(nil)     -- "nil"
tostring(true)    -- "true" 
tostring(false)   -- "false"
```

**Implementation Notes:**
- Numbers use simplified formatting (stub implementation)
- Functions and tables show generic representations
- No metamethod support yet

### io.write(...)

Writes values to standard output without adding a newline.

**Parameters:**
- `...` - Values to write (currently supports single argument)

**Returns:**
- `nil` (simplified; Lua standard returns file object)

**Examples:**
```lua
io.write("Hello")
io.write(" World")
-- Output: "Hello World" (no newline)
```

### print(...)

Writes values to standard output with a newline. Legacy function currently implemented in VM.

**Parameters:**
- `...` - Values to print (currently supports single argument)

**Returns:**
- `nil`

**Examples:**
```lua
print("Hello World")
-- Output: "Hello World\n"
```

## Implementation Details

### Native Function IDs

Each builtin function has a unique identifier in `NativeFnId`:

```zig
pub const NativeFnId = enum(u8) {
    print,    // Legacy print function
    io_write, // io.write function  
    tostring, // tostring function
};
```

### Call Stack Integration

Builtin functions integrate with the VM's call stack through `CallInfo` structures. See [VM Architecture](moonquakes-vm-architecture.md) for details.

### Error Handling

Functions that are not yet implemented in the builtin system return specific errors:

```zig
error.PrintNotImplementedInBuiltin
```

This allows the VM to handle these functions locally during the transition period.

## Future Enhancements

### Planned Features
- Proper number formatting with allocator support
- Multiple argument support for io.write and print
- Additional string functions (string.len, string.sub, etc.)
- Table serialization improvements
- Metamethod support for tostring

### Migration Path
- Move print() from VM to builtin/global.zig
- Implement proper string allocation
- Add more comprehensive I/O functions

