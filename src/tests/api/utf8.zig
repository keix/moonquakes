const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "utf8.char and utf8.codepoint roundtrip codepoints" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local s = utf8.char(65, 0x20AC, 66)
        \\local a, b, c = utf8.codepoint(s, 1, #s)
        \\return s, a, b, c
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("A€B")),
        .{ .integer = 65 },
        .{ .integer = 0x20AC },
        .{ .integer = 66 },
    });
}

test "utf8.len counts codepoints in multibyte strings" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return utf8.len("A€B")
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 3 },
    });
}

test "utf8.offset returns byte positions for characters" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local s = "A€B"
        \\return utf8.offset(s, 1), utf8.offset(s, 2), utf8.offset(s, 3), utf8.offset(s, 0, 3)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 5 },
        .{ .integer = 2 },
    });
}

test "utf8.codes iterates byte positions and codepoints" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local out = {}
        \\for pos, cp in utf8.codes("A€B") do
        \\  out[#out + 1] = pos
        \\  out[#out + 1] = cp
        \\end
        \\local a, b, c, d, e, f = table.unpack(out)
        \\return a, b, c, d, e, f
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .integer = 65 },
        .{ .integer = 2 },
        .{ .integer = 0x20AC },
        .{ .integer = 5 },
        .{ .integer = 66 },
    });
}

test "utf8.charpattern is exposed" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return type(utf8.charpattern), #utf8.charpattern > 0
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("string")),
        .{ .boolean = true },
    });
}
