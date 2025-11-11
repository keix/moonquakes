const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;

test "TValue.eql: basic equality" {
    // nil == nil
    try testing.expect(TValue.eql(.nil, .nil));

    // boolean equality
    try testing.expect(TValue.eql(.{ .boolean = true }, .{ .boolean = true }));
    try testing.expect(TValue.eql(.{ .boolean = false }, .{ .boolean = false }));
    try testing.expect(!TValue.eql(.{ .boolean = true }, .{ .boolean = false }));

    // integer equality
    try testing.expect(TValue.eql(.{ .integer = 42 }, .{ .integer = 42 }));
    try testing.expect(!TValue.eql(.{ .integer = 42 }, .{ .integer = 43 }));

    // number equality
    try testing.expect(TValue.eql(.{ .number = 3.14 }, .{ .number = 3.14 }));
    try testing.expect(!TValue.eql(.{ .number = 3.14 }, .{ .number = 2.71 }));
}

test "TValue.eql: Lua 5.3+ numeric equality (integer vs number)" {
    // 1 == 1.0 should be true
    try testing.expect(TValue.eql(.{ .integer = 1 }, .{ .number = 1.0 }));
    try testing.expect(TValue.eql(.{ .number = 1.0 }, .{ .integer = 1 }));

    // 42 == 42.0
    try testing.expect(TValue.eql(.{ .integer = 42 }, .{ .number = 42.0 }));
    try testing.expect(TValue.eql(.{ .number = 42.0 }, .{ .integer = 42 }));

    // -100 == -100.0
    try testing.expect(TValue.eql(.{ .integer = -100 }, .{ .number = -100.0 }));
    try testing.expect(TValue.eql(.{ .number = -100.0 }, .{ .integer = -100 }));

    // 0 == 0.0
    try testing.expect(TValue.eql(.{ .integer = 0 }, .{ .number = 0.0 }));
    try testing.expect(TValue.eql(.{ .number = 0.0 }, .{ .integer = 0 }));
}

test "TValue.eql: numeric inequality" {
    // integer != non-integer float
    try testing.expect(!TValue.eql(.{ .integer = 1 }, .{ .number = 1.5 }));
    try testing.expect(!TValue.eql(.{ .number = 1.5 }, .{ .integer = 1 }));

    // different integers
    try testing.expect(!TValue.eql(.{ .integer = 42 }, .{ .number = 43.0 }));
    try testing.expect(!TValue.eql(.{ .number = 42.0 }, .{ .integer = 43 }));
}

test "TValue.eql: cross-type inequality" {
    // nil != any other type
    try testing.expect(!TValue.eql(.nil, .{ .boolean = false }));
    try testing.expect(!TValue.eql(.nil, .{ .integer = 0 }));
    try testing.expect(!TValue.eql(.nil, .{ .number = 0.0 }));

    // boolean != numeric types
    try testing.expect(!TValue.eql(.{ .boolean = true }, .{ .integer = 1 }));
    try testing.expect(!TValue.eql(.{ .boolean = false }, .{ .integer = 0 }));
    try testing.expect(!TValue.eql(.{ .boolean = true }, .{ .number = 1.0 }));

    // different types are never equal (except integer/number)
    try testing.expect(!TValue.eql(.{ .integer = 0 }, .nil));
    try testing.expect(!TValue.eql(.{ .number = 0.0 }, .nil));
    try testing.expect(!TValue.eql(.{ .boolean = false }, .nil));
}

test "TValue.eql: edge cases" {
    // Large integer values
    const large: i64 = 1 << 53; // Beyond f64 exact precision
    try testing.expect(TValue.eql(.{ .integer = large }, .{ .integer = large }));

    // NaN is never equal to itself
    const nan = std.math.nan(f64);
    try testing.expect(!TValue.eql(.{ .number = nan }, .{ .number = nan }));

    // Positive and negative zero (in float)
    try testing.expect(TValue.eql(.{ .number = 0.0 }, .{ .number = -0.0 }));

    // Integer overflow when converting to float
    const max_exact_int: i64 = 9007199254740992; // 2^53
    try testing.expect(TValue.eql(.{ .integer = max_exact_int }, .{ .number = @as(f64, @floatFromInt(max_exact_int)) }));
}

test "TValue.eql: NaN comparisons" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // NaN != NaN
    try testing.expect(!TValue.eql(.{ .number = nan }, .{ .number = nan }));

    // NaN != any number
    try testing.expect(!TValue.eql(.{ .number = nan }, .{ .number = 0.0 }));
    try testing.expect(!TValue.eql(.{ .number = 0.0 }, .{ .number = nan }));
    try testing.expect(!TValue.eql(.{ .number = nan }, .{ .number = inf }));

    // NaN != integer (via conversion)
    try testing.expect(!TValue.eql(.{ .number = nan }, .{ .integer = 42 }));
    try testing.expect(!TValue.eql(.{ .integer = 42 }, .{ .number = nan }));
}
