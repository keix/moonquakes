const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

fn writeFixture(path: []const u8, contents: []const u8) !void {
    const cwd = std.fs.cwd();
    cwd.deleteFile(path) catch {};

    const file = try cwd.createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn deleteFixture(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

test "global.assert returns all arguments on success" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local a, b, c = assert(1, "ok", true)
        \\return a, b, c
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        TValue.fromString(try ctx.base.gc().allocString("ok")),
        .{ .boolean = true },
    });
}

test "global.type reports Lua type names" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return type(nil), type(false), type(1), type("x"), type({}), type(function() end)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("nil")),
        TValue.fromString(try ctx.base.gc().allocString("boolean")),
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromString(try ctx.base.gc().allocString("string")),
        TValue.fromString(try ctx.base.gc().allocString("table")),
        TValue.fromString(try ctx.base.gc().allocString("function")),
    });
}

test "global.tonumber parses numbers and returns nil for invalid input" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return tonumber("42"), tonumber("nope")
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 42 },
        .nil,
    });
}

test "global.pcall returns false and error message on Lua error" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(function() error("boom") end)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "boom");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "global.xpcall returns handler result" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = xpcall(
        \\  function() error("boom") end,
        \\  function(e) return "handled:" .. e end
        \\)
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "handled:");
            try api.expectStringContains(err_str.asSlice(), "boom");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "global.load returns executable chunk" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local f = assert(load("return 40 + 2"))
        \\return f()
    );

    try api.expectSingleInteger(result, 42);
}

test "global.load reports syntax errors as nil plus message" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local f, err = load("local =")
        \\return f, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0] == .nil);
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try testing.expect(err_str.asSlice().len > 0);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "global.load supports reader functions and explicit environments" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local pieces = { "return answer + 1", nil }
        \\local i = 0
        \\local env = { answer = 41 }
        \\local f = assert(load(function()
        \\  i = i + 1
        \\  return pieces[i]
        \\end, "=(reader)", "t", env))
        \\return f(), i
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 42 },
        .{ .integer = 2 },
    });
}

test "global.load rejects text chunks in binary-only mode" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local f, err = load("return 1", "=(binary-only)", "b")
        \\return f, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0] == .nil);
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "text chunk");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "global.loadfile uses file content and explicit environment" {
    const path = "tmp_api_loadfile.lua";
    try writeFixture(path, "return injected * 2");
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local env = {{ injected = 21 }}
        \\local f = assert(loadfile("{s}", "t", env))
        \\return f()
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectSingleInteger(result, 42);
}

test "global.dofile executes file chunks and returns all results" {
    const path = "tmp_api_dofile.lua";
    try writeFixture(path, "return 7, 'ok'");
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\return dofile("{s}")
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 7 },
        TValue.fromString(try ctx.base.gc().allocString("ok")),
    });
}
