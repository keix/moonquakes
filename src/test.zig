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

test {
    // This will include all tests from imported modules
    std.testing.refAllDecls(@This());
}
