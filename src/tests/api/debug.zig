const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "debug.getregistry returns the registry table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local a = debug.getregistry()
        \\local b = debug.getregistry()
        \\return type(a), a == b
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("table")),
        .{ .boolean = true },
    });
}

test "debug.setmetatable and debug.getmetatable work for primitive values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local mt = { tag = "num" }
        \\local v = debug.setmetatable(1, mt)
        \\local got = debug.getmetatable(1)
        \\return v, got == mt, got.tag
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("num")),
    });
}

test "debug.getinfo exposes function identity and arity metadata" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function f(a, b, ...)
        \\  return a + b
        \\end
        \\local info = debug.getinfo(f, "fu")
        \\return type(info), info.func == f, info.nparams, info.isvararg, info.nups
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("table")),
        .{ .boolean = true },
        .{ .integer = 2 },
        .{ .boolean = true },
        .{ .integer = 0 },
    });
}

test "debug.sethook and debug.gethook roundtrip hook settings" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local hook = function() end
        \\debug.sethook(hook, "cr", 7)
        \\local f, mask, count = debug.gethook()
        \\debug.sethook()
        \\local f2, mask2, count2 = debug.gethook()
        \\return f == hook, mask, count, f2 == nil, mask2, count2
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("cr")),
        .{ .integer = 7 },
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("")),
        .{ .integer = 0 },
    });
}

test "debug.getupvalue and debug.setupvalue expose and update closure state" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local x = 41
        \\local function f()
        \\  return x
        \\end
        \\local name1, value1 = debug.getupvalue(f, 1)
        \\local name2 = debug.setupvalue(f, 1, 99)
        \\return name1, value1, name2, f()
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("x")),
        .{ .integer = 41 },
        TValue.fromString(try ctx.base.gc().allocString("x")),
        .{ .integer = 99 },
    });
}

test "debug.upvalueid and debug.upvaluejoin can merge upvalue identity" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local x = 10
        \\local y = 20
        \\local function f() return x end
        \\local function g() return y end
        \\local before_same = debug.upvalueid(f, 1) == debug.upvalueid(g, 1)
        \\debug.upvaluejoin(f, 1, g, 1)
        \\debug.setupvalue(g, 1, 77)
        \\local after_same = debug.upvalueid(f, 1) == debug.upvalueid(g, 1)
        \\return before_same, after_same, f(), g()
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = false },
        .{ .boolean = true },
        .{ .integer = 77 },
        .{ .integer = 77 },
    });
}

test "debug.getlocal exposes parameter names for function objects" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function f(alpha, beta, ...)
        \\  return alpha + beta
        \\end
        \\local name1, value1 = debug.getlocal(f, 1)
        \\local name2, value2 = debug.getlocal(f, 2)
        \\local name3, value3 = debug.getlocal(f, 3)
        \\return name1, value1, name2, value2, name3, value3
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("alpha")),
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("beta")),
        .nil,
        .nil,
        .nil,
    });
}

test "debug.getlocal and debug.setlocal can inspect and mutate active caller locals" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function target(a)
        \\  local function probe()
        \\    local name, value = debug.getlocal(2, 1)
        \\    local setname = debug.setlocal(2, 1, 99)
        \\    return name, value, setname
        \\  end
        \\  local name, value, setname = probe()
        \\  return name, value, setname, a
        \\end
        \\return target(41)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("a")),
        .{ .integer = 41 },
        TValue.fromString(try ctx.base.gc().allocString("a")),
        .{ .integer = 99 },
    });
}

test "debug.getlocal and debug.setlocal distinguish missing locals from bad levels" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function f(alpha)
        \\  local name, value = debug.getlocal(f, 999)
        \\  local setname = debug.setlocal(1, 999, 42)
        \\  local ok, err = pcall(function()
        \\    debug.getlocal(999, 1)
        \\  end)
        \\  return name, value, setname, ok, err
        \\end
        \\return f(1)
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 5), values.len);
            try testing.expect(values[0] == .nil);
            try testing.expect(values[1] == .nil);
            try testing.expect(values[2] == .nil);
            try testing.expect(values[3].eql(.{ .boolean = false }));
            const err = values[4].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "level out of range");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "debug.newuserdata and uservalue accessors expose userdata state" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ud = debug.newuserdata(8, 2)
        \\local before1, ok1 = debug.getuservalue(ud, 1)
        \\local before3, ok3 = debug.getuservalue(ud, 3)
        \\local same = debug.setuservalue(ud, "hello", 1) == ud
        \\local after1, ok_after1 = debug.getuservalue(ud, 1)
        \\return type(ud), before1, ok1, before3, ok3, same, after1, ok_after1
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("userdata")),
        .nil,
        .{ .boolean = true },
        .nil,
        .{ .boolean = false },
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("hello")),
        .{ .boolean = true },
    });
}

test "debug.traceback returns traceback text" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local function inner()
        \\  return debug.traceback("boom")
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
        },
        else => return error.TestUnexpectedResult,
    }
}
