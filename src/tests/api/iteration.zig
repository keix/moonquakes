const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "iteration next walks sequential array slots and ends with nil" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = {10, 20}
        \\local k1, v1 = next(t)
        \\local k2, v2 = next(t, k1)
        \\local k3, v3 = next(t, k2)
        \\return k1, v1, k2, v2, k3, v3
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .integer = 10 },
        .{ .integer = 2 },
        .{ .integer = 20 },
        .nil,
        .nil,
    });
}

test "iteration pairs default path returns next table and nil seed" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = { a = 1 }
        \\local iter, state, seed = pairs(t)
        \\local k, v = iter(state, seed)
        \\return type(iter), state == t, seed, k, v
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("function")),
        .{ .boolean = true },
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("a")),
        .{ .integer = 1 },
    });
}

test "iteration pairs honors __pairs metamethod" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = setmetatable({}, {
        \\  __pairs = function(self)
        \\    local done = false
        \\    return function(_, last)
        \\      if done then return nil end
        \\      done = true
        \\      return "virtual", 42
        \\    end, self, "seed"
        \\  end
        \\})
        \\local out = {}
        \\for k, v in pairs(t) do
        \\  out[#out + 1] = k .. "=" .. v
        \\end
        \\return table.concat(out, ",")
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("virtual=42", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "iteration ipairs uses shared iterator and stops at first nil" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = {11, 22, nil, 44}
        \\local iter1 = ipairs({})
        \\local iter2 = ipairs({})
        \\local iter, state, seed = ipairs(t)
        \\local a, b = iter(state, seed)
        \\local c, d = iter(state, a)
        \\local e, f = iter(state, c)
        \\return iter1 == iter2, a, b, c, d, e, f
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        .{ .integer = 1 },
        .{ .integer = 11 },
        .{ .integer = 2 },
        .{ .integer = 22 },
        .nil,
        .nil,
    });
}

test "iteration ipairs honors __index fallback for missing array entries" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local t = setmetatable({ [1] = "a" }, {
        \\  __index = function(_, k)
        \\    if k == 2 then return "b" end
        \\  end
        \\})
        \\local out = {}
        \\for i, v in ipairs(t) do
        \\  out[#out + 1] = i .. ":" .. v
        \\end
        \\return table.concat(out, ",")
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("1:a,2:b", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "iteration next rejects invalid continuation keys" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function()
        \\  return next({ a = 1 }, "missing")
        \\end)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "invalid key");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "iteration next rejects non table first argument with Lua error shape" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function()
        \\  return next(nil)
        \\end)
        \\return ok, type(err), err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 3), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            try testing.expect(values[1].eql(TValue.fromString(try ctx.base.gc().allocString("string"))));
            const err = values[2].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "table expected");
        },
        else => return error.TestUnexpectedResult,
    }
}
