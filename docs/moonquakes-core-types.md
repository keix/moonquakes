# Moonquakes Core Types

## Overview

Moonquakes implements Lua's dynamic type system through the `TValue` union type and supporting structures. This document describes the core type system and data representations.

## TValue - Tagged Union Type

```zig
pub const TValue = union(ValueType) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,
    closure: *const Closure,
    function: Function,
    string: []const u8,
    table: *Table,
};
```

### Value Types

```zig
pub const ValueType = enum(u8) {
    nil,
    boolean,
    integer,
    number,
    closure,
    function,
    string,
    table,
};
```

### Type-Specific Representations

#### Nil
- Represents Lua's `nil` value
- No additional data storage required

#### Boolean  
- Standard Zig `bool` type
- `true` or `false` values

#### Numbers
- **Integer**: 64-bit signed integer (`i64`)
- **Number**: 64-bit floating point (`f64`) 
- Automatic coercion between types in arithmetic

#### Strings
- Stored as `[]const u8` (byte slices)
- Currently no string interning
- Literal strings from parser

#### Functions

```zig
pub const Function = union(FunctionType) {
    bytecode: *const Proto,
    native: NativeFn,
};
```

Two function types:
- **Bytecode**: Compiled Lua functions
- **Native**: Built-in functions implemented in Zig

#### Tables
- Hash table implementation  
- Pointer to `Table` structure
- Supports both array and hash parts

#### Closures
- Function with upvalue capture
- Pointer to `Closure` structure
- Lexical scoping support

## Function Representations

### Native Functions

```zig
pub const NativeFn = struct {
    id: NativeFnId,
};

pub const NativeFnId = enum(u8) {
    print,
    io_write,
    tostring,
};
```

Native functions are identified by unique IDs and dispatched through the builtin system.

### Bytecode Functions (Proto)

```zig
pub const Proto = struct {
    code: []const Instruction,
    k: []const TValue,        // Constants table
    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
};
```

- **code**: Array of VM instructions
- **k**: Constants referenced by instructions  
- **numparams**: Number of fixed parameters
- **is_vararg**: Whether function accepts variable arguments
- **maxstacksize**: Maximum stack size needed

## Table Implementation

```zig
pub const Table = struct {
    // Hash table implementation
    // Supports both array and hash parts
};
```

Tables serve as:
- Arrays (integer indices)
- Hash tables (any value keys)
- Objects (string keys)
- Global environment storage

## Value Operations

### Type Checking

```zig
pub fn isNil(self: TValue) bool
pub fn isBoolean(self: TValue) bool
pub fn isInteger(self: TValue) bool
pub fn isNumber(self: TValue) bool
pub fn isString(self: TValue) bool
pub fn isFunction(self: TValue) bool
pub fn isTable(self: TValue) bool
```

### Type Conversion

```zig
pub fn toNumber(self: TValue) ?f64
pub fn toBoolean(self: TValue) bool
pub fn toClosure(self: TValue) ?*const Closure
```

### Value Comparison

```zig
pub fn eql(a: TValue, b: TValue) bool
```

Implements Lua equality semantics:
- Same type and value equality
- Integer/number coercion
- Reference equality for tables/functions

### Formatting and Display

```zig
pub fn format(
    self: TValue,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void
```

Used by:
- `tostring()` conversion
- Debug output
- Error messages

## Memory Layout

### Stack Storage
Values are stored directly in the VM stack as `TValue` instances.

### Heap Objects
- Tables, closures, and some strings allocated on heap
- Reference counting or GC (future)
- Pointer-based access

### Constant Storage
- String and number literals stored in Proto constants table
- Shared across function instances
- Immutable references

## Type Coercion Rules

### Arithmetic Operations
- Integer + Integer → Integer (with overflow check)  
- Integer + Number → Number
- Number + Number → Number
- String to number conversion (future)

### Comparison Operations
- Same-type comparison preferred
- Integer/Number coercion allowed
- String comparison lexicographic

### Boolean Context
- `nil` and `false` are falsy
- All other values are truthy
- No automatic string/number to boolean conversion

## Integration with VM

### Register Storage
Each VM register contains one `TValue`:

```text
Register 0: TValue{ .number = 42.0 }
Register 1: TValue{ .string = "hello" }  
Register 2: TValue{ .nil = {} }
```

### Function Calls
- Arguments passed as TValue array
- Return values placed in specific registers
- Type checking at runtime

### Global Environment
Global variables stored in root table:

```lua
globals["print"] = TValue{ .function = Function{ .native = ... }}
globals["io"] = TValue{ .table = io_table }
```

## Future Enhancements

### Planned Features
- String interning
- Garbage collection
- Userdata type
- Metamethod support
- Weak references

### Performance Optimizations
- Type specialization
- Inline caching
- Tagged pointer optimization

