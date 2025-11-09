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

test {
    // This will include all tests from imported modules
    std.testing.refAllDecls(@This());
}
