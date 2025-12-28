# Function System Tests

Tests for the new Function architecture implementing proper separation of concerns.

## Structure

- `global/` - Global functions (print)
- `io/` - I/O library functions (io.write)

## Key Features Tested

### Global Functions
- `print()` - Adds newline, returns nil
- Direct global access without namespace

### IO Library Functions  
- `io.write()` - No newline, returns file object (simplified as nil)
- Table-based namespace access

## Architecture

The Function system implements the correct design principle:
> **id is part of "being a function", VM just executes it**

### Core Components
```
NativeFnId (enum) → Function (union) → TValue → VM dispatch
```

### Responsibility Separation
- **core/native.zig**: ID definitions
- **core/function.zig**: Function abstraction  
- **vm/vm.zig**: Simple dispatcher (callNative)
- **VM**: Just a bridge, no semantics

## Expected Behavior

### print vs io.write
```lua
io.write("A"); io.write("B"); print("C"); print("D")
```
**Output**: 
```
ABC
D
```

### Function Values
- Both `print` and `io.write` are proper Function values
- `print`: Direct global access
- `io.write`: Table field access (`io["write"]`)

## Test Files

### global/
- `print.lua` - Basic print functionality
- `print_with_return.lua` - Multiple print calls
- `mixed_output.lua` - print + io.write combination

### io/
- `write.lua` - Basic io.write functionality