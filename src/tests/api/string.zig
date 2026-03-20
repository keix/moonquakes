const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "string library is available through string metatable index" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local mt = debug.getmetatable("")
        \\return type(mt), mt.__index == string
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("table")),
        .{ .boolean = true },
    });
}

test "string.len and string.sub follow Lua indexing rules" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return string.len("hello"), string.sub("hello", 2, 4), string.sub("hello", -2), string.sub("hello", 4, 2)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 5 },
        TValue.fromString(try ctx.base.gc().allocString("ell")),
        TValue.fromString(try ctx.base.gc().allocString("lo")),
        TValue.fromString(try ctx.base.gc().allocString("")),
    });
}

test "string.upper string.lower and string.reverse transform text" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return string.upper("Abc!"), string.lower("AbC!"), string.reverse("stressed")
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("ABC!")),
        TValue.fromString(try ctx.base.gc().allocString("abc!")),
        TValue.fromString(try ctx.base.gc().allocString("desserts")),
    });
}

test "string.byte and string.char roundtrip byte values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local a, b = string.byte("AZ", 1, 2)
        \\return a, b, string.char(65, 90)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 65 },
        .{ .integer = 90 },
        TValue.fromString(try ctx.base.gc().allocString("AZ")),
    });
}

test "string.rep repeats with separator" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return string.rep("ha", 3, "-")
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("ha-ha-ha", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "string.find and string.match return expected captures" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local i, j = string.find("hello world", "world")
        \\local m = string.match("abc123xyz", "%d+")
        \\return i, j, m
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 7 },
        .{ .integer = 11 },
        TValue.fromString(try ctx.base.gc().allocString("123")),
    });
}

test "string.gsub returns replaced string and replacement count" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local s, n = string.gsub("a b a", "a", "x")
        \\return s, n
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("x b x")),
        .{ .integer = 2 },
    });
}
