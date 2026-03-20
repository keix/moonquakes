const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "coroutine.running identifies the main thread" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local co, is_main = coroutine.running()
        \\return type(co), is_main
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("thread")),
        .{ .boolean = true },
    });
}

test "coroutine.create and coroutine.status report lifecycle" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local co = coroutine.create(function() return 42 end)
        \\local before = coroutine.status(co)
        \\local ok, value = coroutine.resume(co)
        \\local after = coroutine.status(co)
        \\return before, ok, value, after
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("suspended")),
        .{ .boolean = true },
        .{ .integer = 42 },
        TValue.fromString(try ctx.base.gc().allocString("dead")),
    });
}

test "coroutine.resume returns yielded values and resume values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local co = coroutine.create(function(a)
        \\  local x, y = coroutine.yield(a + 1, a + 2)
        \\  return x + y
        \\end)
        \\local ok1, y1, y2 = coroutine.resume(co, 10)
        \\local ok2, done = coroutine.resume(co, 20, 30)
        \\return ok1, y1, y2, ok2, done, coroutine.status(co)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        .{ .integer = 11 },
        .{ .integer = 12 },
        .{ .boolean = true },
        .{ .integer = 50 },
        TValue.fromString(try ctx.base.gc().allocString("dead")),
    });
}

test "coroutine.resume returns false plus error on failure" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local co = coroutine.create(function() error("boom") end)
        \\local ok, err = coroutine.resume(co)
        \\return ok, err, coroutine.status(co)
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 3), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "boom");
            try testing.expect(values[2].eql(TValue.fromString(try ctx.base.gc().allocString("dead"))));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "coroutine.wrap returns values and propagates errors" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local w = coroutine.wrap(function()
        \\  coroutine.yield(1, 2)
        \\  error("wrapped boom")
        \\end)
        \\local a, b = w()
        \\local ok, err = pcall(w)
        \\return a, b, ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 4), values.len);
            try testing.expect(values[0].eql(.{ .integer = 1 }));
            try testing.expect(values[1].eql(.{ .integer = 2 }));
            try testing.expect(values[2].eql(.{ .boolean = false }));
            const err_str = values[3].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "wrapped boom");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "coroutine.isyieldable reports main thread as not yieldable" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return coroutine.isyieldable()
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = false },
    });
}

test "coroutine.close closes a suspended coroutine" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local co = coroutine.create(function()
        \\  coroutine.yield("pause")
        \\end)
        \\local ok1, msg = coroutine.resume(co)
        \\local ok2, cerr = coroutine.close(co)
        \\return ok1, msg, ok2, cerr == nil, coroutine.status(co)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("pause")),
        .{ .boolean = true },
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("dead")),
    });
}
