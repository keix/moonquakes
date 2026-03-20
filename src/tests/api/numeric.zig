const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "numeric tonumber handles decimal base conversion and hex literals" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return tonumber("42"), tonumber("1010", 2), tonumber("0x10"), tonumber("0x1.8p1"), tonumber("nan")
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 5), values.len);
            try testing.expect(values[0].eql(.{ .integer = 42 }));
            try testing.expect(values[1].eql(.{ .integer = 10 }));
            try testing.expect(values[2].eql(.{ .integer = 16 }));
            switch (values[3]) {
                .number => |n| try testing.expectApproxEqAbs(@as(f64, 3.0), n, 1e-12),
                else => return error.TestUnexpectedResult,
            }
            try testing.expect(values[4] == .nil);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "numeric tostring preserves Lua scalar formatting" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return tostring(42), tostring(1.0), tostring(true), tostring(nil)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("42")),
        TValue.fromString(try ctx.base.gc().allocString("1.0")),
        TValue.fromString(try ctx.base.gc().allocString("true")),
        TValue.fromString(try ctx.base.gc().allocString("nil")),
    });
}

test "numeric rawlen bypasses __len and rawequal ignores metamethods" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local mt = {
        \\  __len = function() return 99 end,
        \\  __eq = function() return true end,
        \\}
        \\local a = setmetatable({1, 2, 3}, mt)
        \\local b = setmetatable({}, mt)
        \\return #a, rawlen(a), a == b, rawequal(a, b)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 99 },
        .{ .integer = 3 },
        .{ .boolean = true },
        .{ .boolean = false },
    });
}

test "numeric select returns counts suffixes and negative indexes" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local c = select("#", "a", "b", "c")
        \\local x, y = select(2, 10, 20, 30)
        \\local z = select(-1, 10, 20, 30)
        \\return c, x, y, z
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 3 },
        .{ .integer = 20 },
        .{ .integer = 30 },
        .{ .integer = 30 },
    });
}

test "numeric equality and math type distinguish integer and float" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return 1 == 1.0, math.type(1), math.type(1.0), math.tointeger(1.0), math.tointeger(1.5)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("integer")),
        TValue.fromString(try ctx.base.gc().allocString("float")),
        .{ .integer = 1 },
        .nil,
    });
}
