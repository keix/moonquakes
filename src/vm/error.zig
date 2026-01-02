const std = @import("std");

/// Three-Tier Error Handling System for Moonquakes
///
/// 1. Internal Truth Layer (VM): Accurate, mechanical error types for VM correctness
/// 2. Sugar Layer (Standard Library): Translates internal errors to Lua-native concepts
/// 3. Expression Layer (User Code): assert(), error(), collectgarbage() functions
/// Internal VM error types (Truth Layer)
/// These represent the actual mechanical failures within the VM
pub const VMError = error{
    // Execution Control Errors
    PcOutOfRange,
    CallStackOverflow,
    UnknownOpcode,
    VariableReturnNotImplemented,

    // Type & Arithmetic Errors
    ArithmeticError,
    OrderComparisonError,
    LengthError,

    // For Loop Parameter Errors
    InvalidForLoopInit,
    InvalidForLoopStep,
    InvalidForLoopLimit,

    // Function Call Errors
    NotAFunction,

    // Table Operation Errors
    InvalidTableKey,
    InvalidTableOperation,
};

/// Sugar Layer error categories
/// These represent Lua-native error concepts that users understand
pub const LuaErrorKind = enum {
    runtime_error, // General runtime errors
    type_error, // Wrong type for operation
    arithmetic_error, // Math operation failed
    call_error, // Function call failed
    table_error, // Table operation failed
    loop_error, // For loop parameter error
    memory_error, // Out of memory
    stack_overflow, // Stack overflow
    syntax_error, // Parse error (from compiler)
};

/// Sugar Layer error message
pub const LuaError = struct {
    kind: LuaErrorKind,
    message: []const u8,
    location: ?SourceLocation = null,
};

/// Source location for error reporting
pub const SourceLocation = struct {
    line: u32,
    column: u32,
    function_name: ?[]const u8 = null,
};

/// Sugar Layer: Translate VM errors to Lua error messages
pub fn translateVMError(vm_error: VMError, allocator: std.mem.Allocator) !LuaError {
    return switch (vm_error) {
        error.PcOutOfRange => LuaError{
            .kind = .runtime_error,
            .message = try allocator.dupe(u8, "attempt to execute beyond program boundary"),
        },
        error.CallStackOverflow => LuaError{
            .kind = .stack_overflow,
            .message = try allocator.dupe(u8, "stack overflow"),
        },
        error.UnknownOpcode => LuaError{
            .kind = .runtime_error,
            .message = try allocator.dupe(u8, "attempt to execute invalid instruction"),
        },
        error.VariableReturnNotImplemented => LuaError{
            .kind = .runtime_error,
            .message = try allocator.dupe(u8, "variable return not yet implemented"),
        },
        error.ArithmeticError => LuaError{
            .kind = .arithmetic_error,
            .message = try allocator.dupe(u8, "attempt to perform arithmetic on non-numeric values"),
        },
        error.OrderComparisonError => LuaError{
            .kind = .type_error,
            .message = try allocator.dupe(u8, "attempt to compare non-comparable values"),
        },
        error.LengthError => LuaError{
            .kind = .type_error,
            .message = try allocator.dupe(u8, "attempt to get length of non-string value"),
        },
        error.InvalidForLoopInit, error.InvalidForLoopStep, error.InvalidForLoopLimit => LuaError{
            .kind = .loop_error,
            .message = try allocator.dupe(u8, "'for' loop parameters must be numbers"),
        },
        error.NotAFunction => LuaError{
            .kind = .call_error,
            .message = try allocator.dupe(u8, "attempt to call non-function value"),
        },
        error.InvalidTableKey => LuaError{
            .kind = .table_error,
            .message = try allocator.dupe(u8, "table index is nil or NaN"),
        },
        error.InvalidTableOperation => LuaError{
            .kind = .table_error,
            .message = try allocator.dupe(u8, "attempt to index non-table value"),
        },
    };
}

/// Format LuaError as user-friendly string
pub fn formatLuaError(lua_error: LuaError, allocator: std.mem.Allocator) ![]const u8 {
    if (lua_error.location) |loc| {
        if (loc.function_name) |fname| {
            return try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: runtime error: {s}", .{ fname, loc.line, loc.column, lua_error.message });
        } else {
            return try std.fmt.allocPrint(allocator, "{d}:{d}: runtime error: {s}", .{ loc.line, loc.column, lua_error.message });
        }
    } else {
        return try std.fmt.allocPrint(allocator, "runtime error: {s}", .{lua_error.message});
    }
}

/// Sugar Layer: Error reporting function
/// This is the bridge between VM internal errors and Lua error handling
pub fn reportError(vm_error: VMError, allocator: std.mem.Allocator, location: ?SourceLocation) ![]const u8 {
    const lua_error = try translateVMError(vm_error, allocator);
    defer allocator.free(lua_error.message);

    var error_with_location = lua_error;
    error_with_location.location = location;

    return try formatLuaError(error_with_location, allocator);
}

test "VM error translation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test arithmetic error translation
    const arith_error = try translateVMError(error.ArithmeticError, allocator);
    defer allocator.free(arith_error.message);
    try testing.expect(arith_error.kind == .arithmetic_error);
    try testing.expect(std.mem.eql(u8, arith_error.message, "attempt to perform arithmetic on non-numeric values"));

    // Test call error translation
    const call_error = try translateVMError(error.NotAFunction, allocator);
    defer allocator.free(call_error.message);
    try testing.expect(call_error.kind == .call_error);
    try testing.expect(std.mem.eql(u8, call_error.message, "attempt to call non-function value"));
}

test "error formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lua_error = LuaError{
        .kind = .arithmetic_error,
        .message = "test message",
        .location = SourceLocation{
            .line = 42,
            .column = 10,
            .function_name = "main",
        },
    };

    const formatted = try formatLuaError(lua_error, allocator);
    defer allocator.free(formatted);

    try testing.expect(std.mem.eql(u8, formatted, "main:42:10: runtime error: test message"));
}
