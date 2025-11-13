# Moonquakes Test Framework Guide

This document explains how to use the test_utils utilities for testing the Moonquakes VM.

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [ExecutionTrace - Tracking Execution State](#executiontrace)
3. [Register Verification Utilities](#register-verification-utilities)
4. [VM State Verification](#vm-state-verification)
5. [Return Value Verification](#return-value-verification)
6. [Specialized Test Patterns](#specialized-test-patterns)
7. [Best Practices](#best-practices)

## Core Concepts

Moonquakes VM tests verify the following elements:
- **Instruction correctness**: Expected computation results
- **Register state**: Each register is updated correctly
- **Side effects**: Unrelated registers remain unchanged
- **VM state consistency**: base and top pointers are correct

## ExecutionTrace

A struct for recording and comparing register states before and after execution.

```zig
// Usage example
var vm = VM.init();
var trace = utils.ExecutionTrace.captureInitial(&vm, 4); // Track R0-R3
const result = try vm.execute(&proto);
trace.updateFinal(&vm, 4); // Record post-execution state
```

### Main Methods

- `captureInitial(vm, reg_count)`: Record pre-execution state
- `updateFinal(vm, reg_count)`: Record post-execution state
- `expectRegisterChanged(reg, expected)`: Verify specific register change
- `expectRegisterUnchanged(reg)`: Verify register hasn't changed
- `print(reg_count)`: Output changes for debugging

## Register Verification Utilities

### expectRegister
Verify a single register value:
```zig
try utils.expectRegister(&vm, 0, TValue{ .integer = 42 }); // R0 = 42
```

### expectRegisters
Verify multiple registers at once:
```zig
try utils.expectRegisters(&vm, 0, &[_]TValue{
    .{ .integer = 10 },  // R0
    .{ .integer = 20 },  // R1
    .{ .integer = 30 },  // R2
});
```

### expectNilRange
Verify register range is nil:
```zig
try utils.expectNilRange(&vm, 0, 5); // R0-R4 are nil
```

### expectRegistersUnchanged
Verify registers except specified ones haven't changed:
```zig
// Verify R2-R4 are unchanged (except R0,R1)
try utils.expectRegistersUnchanged(&trace, 5, &[_]u8{0, 1});
```

## VM State Verification

### expectVMState
Verify VM base/top pointers:
```zig
try utils.expectVMState(&vm, 0, 3); // base=0, top=3
```

### expectResultAndState
Verify return value and VM state together:
```zig
try utils.expectResultAndState(
    result,
    TValue{ .integer = 42 },  // Expected return value
    &vm,
    0,  // expected base
    3   // expected top
);
```

## Return Value Verification

### ReturnTest struct

```zig
// No return value
try utils.ReturnTest.expectNone(result);

// Single return value
try utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });

// Multiple return values
try utils.ReturnTest.expectMultiple(result, &[_]TValue{
    .{ .integer = 1 },
    .{ .integer = 2 },
    .{ .integer = 3 },
});
```

## Specialized Test Patterns

### ComparisonTest - Comparison Instruction Skip Behavior

Lua 5.4 comparison instructions skip the next instruction based on conditions:

```zig
// Expect skip when condition is true
try utils.ComparisonTest.expectSkip(
    &vm,
    Instruction.initABC(.EQ, 0, 0, 1),  // R0 == R1
    TValue{ .integer = 42 },  // R0 value
    TValue{ .integer = 42 },  // R1 value
    &[_]TValue{}  // Constants table
);

// Expect no skip when condition is false
try utils.ComparisonTest.expectNoSkip(
    &vm,
    Instruction.initABC(.EQ, 0, 0, 1),
    TValue{ .integer = 42 },
    TValue{ .integer = 43 },
    &[_]TValue{}
);
```

### ForLoopTrace - Loop State Tracking

```zig
const loop_trace = utils.ForLoopTrace.capture(&vm, 0); // Start from R0
try loop_trace.expectIntegerPath();  // Uses integer optimization path
try loop_trace.expectFloatPath();    // Uses floating-point path
```

### InstructionTest - Single Instruction Testing

```zig
var inst_test = utils.InstructionTest.init(&vm, &proto, 3);

// Expect success
const trace = try inst_test.expectSuccess(3);

// Expect error
try inst_test.expectError(error.ArithmeticError);
```

### testArithmeticOp - Simplified Arithmetic Testing

```zig
try utils.testArithmeticOp(
    &vm,
    Instruction.initABC(.ADD, 2, 0, 1),  // R2 = R0 + R1
    TValue{ .integer = 10 },  // R0
    TValue{ .integer = 20 },  // R1
    TValue{ .integer = 30 },  // Expected R2
    &[_]TValue{}  // Constants
);
```

### expectSideEffectFree - Verify No Side Effects

```zig
// Only R2 changes, other registers remain unchanged
try utils.expectSideEffectFree(&vm, &proto, &[_]u8{2}, 5);
```

## Best Practices

### 1. Comprehensive Test Structure

```zig
test "BAND: Complete test example" {
    // 1. Prepare test code
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0),
        Instruction.initABx(.LOADK, 1, 1),
        Instruction.initABC(.BAND, 2, 0, 1),
        Instruction.initABC(.RETURN, 2, 2, 0),
    };

    // 2. Initialize VM and record pre-execution state
    var vm = VM.init();
    var trace = utils.ExecutionTrace.captureInitial(&vm, 3);
    
    // 3. Execute
    const result = try vm.execute(&proto);
    trace.updateFinal(&vm, 3);

    // 4. Verify result
    try utils.expectResultAndState(result, expected_value, &vm, 0, 3);
    
    // 5. Verify register states
    try trace.expectRegisterChanged(0, expected_r0);
    try trace.expectRegisterChanged(1, expected_r1);
    try trace.expectRegisterChanged(2, expected_r2);
    
    // 6. Verify no unintended changes
    try utils.expectRegistersUnchanged(&trace, 3, &[_]u8{0, 1, 2});
}
```

### 2. Error Case Testing

```zig
test "Error case" {
    var vm = VM.init();
    const result = vm.execute(&proto);
    try testing.expectError(error.ArithmeticError, result);
}
```

### 3. Side Effect Verification

```zig
test "Side effect verification" {
    var vm = VM.init();
    
    // Set values in unrelated registers
    vm.stack[3] = TValue{ .integer = 999 };
    vm.stack[4] = TValue{ .boolean = true };
    
    _ = try vm.execute(&proto);
    
    // Verify they haven't changed
    try utils.expectRegister(&vm, 3, TValue{ .integer = 999 });
    try utils.expectRegister(&vm, 4, TValue{ .boolean = true });
}
```

### 4. Floating-Point Comparison

```zig
// Compare with tolerance for floating-point errors
try utils.expectApprox(actual, 3.14159, 0.00001);
```

## Debugging Tips

1. **ExecutionTrace.print()**: Visually inspect before/after changes
2. **Verify intermediate results**: Check each step in complex calculations
3. **Boundary testing**: Test max values, min values, zero, negative numbers
4. **Type conversion testing**: Ensure integer/float conversions work correctly

## Summary

test_utils is designed based on these principles:

1. **Explicit**: All verifications are explicit
2. **Comprehensive**: Verify register state, VM state, and return values
3. **Reusable**: Common patterns are factored into utility functions
4. **Debuggable**: Easy to identify failure causes

By leveraging these utilities, you can reliably verify that each VM instruction is correctly implemented.
