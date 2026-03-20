const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "table.pack and table.unpack preserve values and n field" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = table.pack(10, nil, "x")
        \\local a, b, c = table.unpack(t, 1, 3)
        \\return t.n, a, b, c
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 3 },
        .{ .integer = 10 },
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("x")),
    });
}

test "table.concat joins sequential string values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return table.concat({"a", "b", "c"}, "-")
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("a-b-c", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "table.insert and table.remove mutate list positions" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = {1, 3}
        \\table.insert(t, 2, 2)
        \\local removed = table.remove(t, 1)
        \\return removed, t[1], t[2], #t
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
        .{ .integer = 2 },
    });
}

test "table.move copies ranges into destination table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local src = {10, 20, 30}
        \\local dst = {}
        \\table.move(src, 1, 3, 2, dst)
        \\return dst[1], dst[2], dst[3], dst[4]
    );

    try api.expectMultiple(result, &[_]TValue{
        .nil,
        .{ .integer = 10 },
        .{ .integer = 20 },
        .{ .integer = 30 },
    });
}

test "table.sort sorts values in ascending order" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = {4, 1, 3, 2}
        \\table.sort(t)
        \\return t[1], t[2], t[3], t[4]
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
        .{ .integer = 4 },
    });
}
