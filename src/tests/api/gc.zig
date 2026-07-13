const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "gc collectgarbage exposes count running and step contracts" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local count = collectgarbage("count")
        \\local running = collectgarbage("isrunning")
        \\local stepped = collectgarbage("step", 0)
        \\return type(count), running, type(stepped)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromBool(true),
        TValue.fromString(try ctx.base.gc().allocString("boolean")),
    });
}

test "gc collectgarbage stop and restart toggle running state" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local prev = collectgarbage("stop")
        \\local stopped = collectgarbage("isrunning")
        \\collectgarbage("restart")
        \\local restarted = collectgarbage("isrunning")
        \\return type(prev), stopped, restarted
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("boolean")),
        TValue.fromBool(false),
        TValue.fromBool(true),
    });
}

test "gc collectgarbage setpause and setstepmul return previous values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local p1 = collectgarbage("setpause", 150)
        \\local p2 = collectgarbage("setpause", p1)
        \\local s1 = collectgarbage("setstepmul", 200)
        \\local s2 = collectgarbage("setstepmul", s1)
        \\return type(p1), type(p2), type(s1), type(s2)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromString(try ctx.base.gc().allocString("number")),
    });
}

test "gc collectgarbage mode switches report previous mode" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local prev1 = collectgarbage("incremental")
        \\local prev2 = collectgarbage("generational")
        \\local prev3 = collectgarbage("incremental")
        \\return prev1, prev2, prev3
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("incremental")),
        TValue.fromString(try ctx.base.gc().allocString("incremental")),
        TValue.fromString(try ctx.base.gc().allocString("generational")),
    });
}

test "gc collectgarbage rejects invalid options and non integer tuning args" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok1, err1 = pcall(function()
        \\  collectgarbage("wat")
        \\end)
        \\local ok2, err2 = pcall(function()
        \\  collectgarbage("setpause", 1.5)
        \\end)
        \\return ok1, err1, ok2, err2
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 4), values.len);
            try testing.expect(values[0].eql(TValue.fromBool(false)));
            try testing.expect(values[2].eql(TValue.fromBool(false)));
            const err1 = values[1].asString() orelse return error.TestUnexpectedResult;
            const err2 = values[3].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err1.asSlice(), "invalid option");
            try api.expectStringContains(err2.asSlice(), "integer representation");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "gc varargs stored above vm.top survive a collection inside a callee" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    // A vararg frame parks its extra arguments at vararg_base, above
    // base + maxstacksize — and above vm.top while a callee runs. The
    // stack root sweep stops at vm.top, so frame marking must cover the
    // vararg slices explicitly or the churn below recycles them while
    // they are still readable via `...` after the callee returns.
    const result = try ctx.exec(
        \\local function churn()
        \\  for i = 1, 200 do local t = { i, i + 1, tostring(i) .. "pad" } end
        \\  collectgarbage("collect")
        \\  collectgarbage("collect")
        \\  for i = 1, 200 do local t = { i * 2, "fill" .. tostring(i) } end
        \\end
        \\local function v(...)
        \\  churn()
        \\  local a, b, c = ...
        \\  return a[1], b[1], c[1]
        \\end
        \\return v({11}, {22}, {33})
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromInt(11),
        TValue.fromInt(22),
        TValue.fromInt(33),
    });
}
