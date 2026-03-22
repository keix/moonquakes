const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "error pcall preserves success flag and all return values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, a, b = pcall(function()
        \\  return 1, 2
        \\end)
        \\return ok, a, b
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        .{ .integer = 1 },
        .{ .integer = 2 },
    });
}

test "error pcall failure shape is false plus string error object" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function()
        \\  error("x")
        \\end)
        \\return ok, type(err)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = false },
        TValue.fromString(try ctx.base.gc().allocString("string")),
    });
}

test "error level zero returns raw message without source prefix" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function()
        \\  error("boom", 0)
        \\end)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err = values[1].asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("boom", err.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "error default level includes source information" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function()
        \\  error("boom")
        \\end)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "boom");
            try api.expectStringContains(err.asSlice(), "(api-test)");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "error raised with higher level shifts blame outward" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function a()
        \\  error("boom", 2)
        \\end
        \\local function b()
        \\  return a()
        \\end
        \\local ok, err = pcall(b)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "boom");
            try api.expectStringContains(err.asSlice(), "[protected call bootstrap]");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "error xpcall handler receives message and can transform it" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = xpcall(
        \\  function()
        \\    error("boom", 0)
        \\  end,
        \\  function(e)
        \\    return "handled:" .. e
        \\  end
        \\)
        \\return ok, err
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = false },
        TValue.fromString(try ctx.base.gc().allocString("handled:boom")),
    });
}

test "error xpcall reports handler failures with canonical message" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = xpcall(
        \\  function()
        \\    error("boom")
        \\  end,
        \\  function()
        \\    error("handler")
        \\  end
        \\)
        \\return ok, err
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = false },
        TValue.fromString(try ctx.base.gc().allocString("error in error handling")),
    });
}

test "error traceback level skips requested stack frames" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function inner()
        \\  return debug.traceback("boom", 2)
        \\end
        \\local function outer()
        \\  return inner()
        \\end
        \\return outer()
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(s.asSlice(), "boom");
            try api.expectStringContains(s.asSlice(), "stack traceback:");
            try testing.expect(std.mem.indexOf(u8, s.asSlice(), "debug.traceback") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}
