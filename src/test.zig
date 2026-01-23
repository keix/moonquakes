// This is the test entry point that includes all test files
const std = @import("std");

// Include all test modules
pub const basic_tests = @import("tests/basic.zig");
pub const arithmetic_tests = @import("tests/arithmetic.zig");
pub const unary_tests = @import("tests/unary.zig");
pub const returns_tests = @import("tests/returns.zig");
pub const comparison_tests = @import("tests/comparison.zig");
pub const control_flow_tests = @import("tests/control_flow.zig");
pub const for_loop_tests = @import("tests/for_loops.zig");
pub const load_instructions_tests = @import("tests/load_instructions.zig");
pub const immediate_arithmetic_tests = @import("tests/immediate_arithmetic.zig");
pub const constant_arithmetic_tests = @import("tests/constant_arithmetic.zig");
pub const opcodes_tests = @import("tests/opcodes.zig");
pub const value_equality_tests = @import("tests/value_equality.zig");
pub const nan_comparisons_tests = @import("tests/nan_comparisons.zig");
pub const division_by_zero_tests = @import("tests/division_by_zero.zig");
pub const basic_with_utils_tests = @import("tests/basic_with_utils.zig");
pub const bitwise_tests = @import("tests/bitwise.zig");
pub const parser_tests = @import("tests/parser.zig");
pub const multi_proto_tests = @import("tests/multi_proto.zig");
pub const simple_call_tests = @import("tests/simple_call.zig");
pub const extended_load_tests = @import("tests/extended_load.zig");
pub const comparison_extensions_tests = @import("tests/comparison_extensions.zig");
pub const parser_comparison_tests = @import("tests/parser_comparison.zig");
pub const upvalue_opcodes_tests = @import("tests/upvalue_opcodes.zig");
pub const register_scope_tests = @import("tests/register_scope.zig");
// pub const function_calls_tests = @import("tests/function_calls.zig");

test {
    // This will include all tests from imported modules
    std.testing.refAllDecls(@This());
}
