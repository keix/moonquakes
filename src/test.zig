// This is the test entry point that includes all test files
const std = @import("std");

// Include all test modules
pub const basic_tests = @import("tests/basic.zig");
pub const arithmetic_tests = @import("tests/arithmetic.zig");
pub const unary_tests = @import("tests/unary.zig");

test {
    // This will include all tests from imported modules
    std.testing.refAllDecls(@This());
}
