const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "math table exposes core constants" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return math.type(math.maxinteger), math.type(math.mininteger), math.pi > 3, math.huge > 1e100
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("integer")),
        TValue.fromString(try ctx.base.gc().allocString("integer")),
        TValue.fromBool(true),
        TValue.fromBool(true),
    });
}

test "math abs ceil floor max and min preserve numeric behavior" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return math.abs(-4), math.ceil(2.2), math.floor(2.8), math.max(1, 9, 3), math.min(1, 9, 3)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromInt(4),
        TValue.fromInt(3),
        TValue.fromInt(2),
        TValue.fromInt(9),
        TValue.fromInt(1),
    });
}

test "math modf tointeger type and ult expose Lua numeric contracts" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local i, f = math.modf(3.25)
        \\return i, f, math.tointeger("42"), math.type(1.5), math.ult(-1, 1)
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 5), values.len);
            try testing.expect(values[0].eql(TValue.fromInt(3)));
            try testing.expect(values[2].eql(TValue.fromInt(42)));
            const ty = values[3].asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("float", ty.asSlice());
            try testing.expect(values[4].eql(TValue.fromBool(false)));
            switch (values[1].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 0.25), values[1].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "math trig and conversion helpers return expected values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return math.sin(0), math.sqrt(9), math.deg(math.pi), math.rad(180)
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 4), values.len);
            switch (values[0].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 0.0), values[0].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
            switch (values[1].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 3.0), values[1].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
            switch (values[2].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 180.0), values[2].asFloat(), 1e-9),
                else => return error.TestUnexpectedResult,
            }
            switch (values[3].kind()) {
                .number => try testing.expectApproxEqAbs(std.math.pi, values[3].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "math randomseed makes random sequence reproducible" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\math.randomseed(123, 456)
        \\local a1 = math.random()
        \\local a2 = math.random(1, 100)
        \\math.randomseed(123, 456)
        \\local b1 = math.random()
        \\local b2 = math.random(1, 100)
        \\return a1 == b1, a2 == b2, a2 >= 1 and a2 <= 100
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromBool(true),
        TValue.fromBool(true),
        TValue.fromBool(true),
    });
}

test "math random supports zero one and two argument forms" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\math.randomseed(1, 2)
        \\local a = math.random()
        \\local b = math.random(10)
        \\local c = math.random(5, 9)
        \\return type(a), a >= 0 and a < 1, b >= 1 and b <= 10, c >= 5 and c <= 9
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromBool(true),
        TValue.fromBool(true),
        TValue.fromBool(true),
    });
}

test "math fmod log exp cos and atan expose stable numeric behavior" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return math.fmod(17, 5), math.log(8, 2), math.exp(1), math.cos(0), math.atan(0)
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 5), values.len);
            switch (values[0].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 2.0), values[0].asFloat(), 1e-12),
                .integer => try testing.expectEqual(@as(i64, 2), values[0].asInt()),
                else => return error.TestUnexpectedResult,
            }
            switch (values[1].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 3.0), values[1].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
            switch (values[2].kind()) {
                .number => try testing.expect(values[2].asFloat() > 2.7 and values[2].asFloat() < 2.8),
                else => return error.TestUnexpectedResult,
            }
            switch (values[3].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 1.0), values[3].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
            switch (values[4].kind()) {
                .number => try testing.expectApproxEqAbs(@as(f64, 0.0), values[4].asFloat(), 1e-12),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}
