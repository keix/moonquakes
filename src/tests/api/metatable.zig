const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "metatable __index function dispatches missing keys" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = setmetatable({}, {
        \\  __index = function(_, k)
        \\    return k .. "_x"
        \\  end
        \\})
        \\return t.alpha, t.beta
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("alpha_x")),
        TValue.fromString(try ctx.base.gc().allocString("beta_x")),
    });
}

test "metatable __index table chains lookup through fallback table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local fallback = { a = 10, b = 20 }
        \\local t = setmetatable({}, { __index = fallback })
        \\return t.a, t.b, rawget(t, "a"), rawget(fallback, "a")
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 10 },
        .{ .integer = 20 },
        .nil,
        .{ .integer = 10 },
    });
}

test "metatable __newindex function intercepts writes" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local sink = {}
        \\local proxy = setmetatable({}, {
        \\  __newindex = function(_, k, v)
        \\    sink[k] = v * 2
        \\  end
        \\})
        \\proxy.answer = 21
        \\return sink.answer, rawget(proxy, "answer")
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 42 },
        .nil,
    });
}

test "metatable __newindex table redirects writes to target table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local dst = {}
        \\local t = setmetatable({}, { __newindex = dst })
        \\t.value = 42
        \\return rawget(t, "value"), dst.value
    );

    try api.expectMultiple(result, &[_]TValue{
        .nil,
        .{ .integer = 42 },
    });
}

test "metatable raw access bypasses metamethods" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = setmetatable({}, {
        \\  __index = function() return 42 end,
        \\  __newindex = function() error("should not run") end
        \\})
        \\rawset(t, "a", 7)
        \\return rawget(t, "a"), t.a, rawlen("hello")
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 7 },
        .{ .integer = 7 },
        .{ .integer = 5 },
    });
}

test "metatable __len __call and __tostring are honored" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = setmetatable({}, {
        \\  __len = function() return 99 end,
        \\  __call = function(_, x) return x * 2 end,
        \\  __tostring = function() return "META" end,
        \\})
        \\return #t, t(5), tostring(t)
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 99 },
        .{ .integer = 10 },
        TValue.fromString(try ctx.base.gc().allocString("META")),
    });
}

test "metatable protection via __metatable hides and locks the real metatable" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = {}
        \\local mt = { __metatable = "locked", tag = "real" }
        \\setmetatable(t, mt)
        \\local visible = getmetatable(t)
        \\local ok, err = pcall(setmetatable, t, {})
        \\local real = debug.getmetatable(t)
        \\return visible, ok, err, real == mt, real.tag
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 5), values.len);
            try testing.expect(values[0].eql(TValue.fromString(try ctx.base.gc().allocString("locked"))));
            try testing.expect(values[1].eql(.{ .boolean = false }));
            const err = values[2].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "protected metatable");
            try testing.expect(values[3].eql(.{ .boolean = true }));
            try testing.expect(values[4].eql(TValue.fromString(try ctx.base.gc().allocString("real"))));
        },
        else => return error.TestUnexpectedResult,
    }
}
