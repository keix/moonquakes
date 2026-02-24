const std = @import("std");
const err_mod = @import("../vm/error.zig");

const VMError = err_mod.VMError;
const LuaError = err_mod.LuaError;
const SourceLocation = err_mod.SourceLocation;
const translateVMError = err_mod.translateVMError;
const formatLuaError = err_mod.formatLuaError;

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
