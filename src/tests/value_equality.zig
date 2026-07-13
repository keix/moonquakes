const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;

test "TValue.eql: basic equality" {
    // nil == nil
    try testing.expect(TValue.eql(.nil, .nil));

    // boolean equality
    try testing.expect(TValue.eql(TValue.fromBool(true), TValue.fromBool(true)));
    try testing.expect(TValue.eql(TValue.fromBool(false), TValue.fromBool(false)));
    try testing.expect(!TValue.eql(TValue.fromBool(true), TValue.fromBool(false)));

    // integer equality
    try testing.expect(TValue.eql(TValue.fromInt(42), TValue.fromInt(42)));
    try testing.expect(!TValue.eql(TValue.fromInt(42), TValue.fromInt(43)));

    // number equality
    try testing.expect(TValue.eql(TValue.fromFloat(3.14), TValue.fromFloat(3.14)));
    try testing.expect(!TValue.eql(TValue.fromFloat(3.14), TValue.fromFloat(2.71)));
}

test "TValue.eql: Lua 5.3+ numeric equality (integer vs number)" {
    // 1 == 1.0 should be true
    try testing.expect(TValue.eql(TValue.fromInt(1), TValue.fromFloat(1.0)));
    try testing.expect(TValue.eql(TValue.fromFloat(1.0), TValue.fromInt(1)));

    // 42 == 42.0
    try testing.expect(TValue.eql(TValue.fromInt(42), TValue.fromFloat(42.0)));
    try testing.expect(TValue.eql(TValue.fromFloat(42.0), TValue.fromInt(42)));

    // -100 == -100.0
    try testing.expect(TValue.eql(TValue.fromInt(-100), TValue.fromFloat(-100.0)));
    try testing.expect(TValue.eql(TValue.fromFloat(-100.0), TValue.fromInt(-100)));

    // 0 == 0.0
    try testing.expect(TValue.eql(TValue.fromInt(0), TValue.fromFloat(0.0)));
    try testing.expect(TValue.eql(TValue.fromFloat(0.0), TValue.fromInt(0)));
}

test "TValue.eql: numeric inequality" {
    // integer != non-integer float
    try testing.expect(!TValue.eql(TValue.fromInt(1), TValue.fromFloat(1.5)));
    try testing.expect(!TValue.eql(TValue.fromFloat(1.5), TValue.fromInt(1)));

    // different integers
    try testing.expect(!TValue.eql(TValue.fromInt(42), TValue.fromFloat(43.0)));
    try testing.expect(!TValue.eql(TValue.fromFloat(42.0), TValue.fromInt(43)));
}

test "TValue.eql: cross-type inequality" {
    // nil != any other type
    try testing.expect(!TValue.eql(.nil, TValue.fromBool(false)));
    try testing.expect(!TValue.eql(.nil, TValue.fromInt(0)));
    try testing.expect(!TValue.eql(.nil, TValue.fromFloat(0.0)));

    // boolean != numeric types
    try testing.expect(!TValue.eql(TValue.fromBool(true), TValue.fromInt(1)));
    try testing.expect(!TValue.eql(TValue.fromBool(false), TValue.fromInt(0)));
    try testing.expect(!TValue.eql(TValue.fromBool(true), TValue.fromFloat(1.0)));

    // different types are never equal (except integer/number)
    try testing.expect(!TValue.eql(TValue.fromInt(0), .nil));
    try testing.expect(!TValue.eql(TValue.fromFloat(0.0), .nil));
    try testing.expect(!TValue.eql(TValue.fromBool(false), .nil));
}

test "TValue.eql: edge cases" {
    // Large integer values
    const large: i64 = 1 << 53; // Beyond f64 exact precision
    try testing.expect(TValue.eql(TValue.fromInt(large), TValue.fromInt(large)));

    // NaN is never equal to itself
    const nan = std.math.nan(f64);
    try testing.expect(!TValue.eql(TValue.fromFloat(nan), TValue.fromFloat(nan)));

    // Positive and negative zero (in float)
    try testing.expect(TValue.eql(TValue.fromFloat(0.0), TValue.fromFloat(-0.0)));

    // Integer overflow when converting to float
    const max_exact_int: i64 = 9007199254740992; // 2^53
    try testing.expect(TValue.eql(TValue.fromInt(max_exact_int), TValue.fromFloat(@as(f64, @floatFromInt(max_exact_int)))));
}

test "TValue.eql: NaN comparisons" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // NaN != NaN
    try testing.expect(!TValue.eql(TValue.fromFloat(nan), TValue.fromFloat(nan)));

    // NaN != any number
    try testing.expect(!TValue.eql(TValue.fromFloat(nan), TValue.fromFloat(0.0)));
    try testing.expect(!TValue.eql(TValue.fromFloat(0.0), TValue.fromFloat(nan)));
    try testing.expect(!TValue.eql(TValue.fromFloat(nan), TValue.fromFloat(inf)));

    // NaN != integer (via conversion)
    try testing.expect(!TValue.eql(TValue.fromFloat(nan), TValue.fromInt(42)));
    try testing.expect(!TValue.eql(TValue.fromInt(42), TValue.fromFloat(nan)));
}
