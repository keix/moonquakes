const std = @import("std");
const testing = std.testing;

const TValue = @import("../../runtime/value.zig").TValue;
const api = @import("test_api_utils.zig");

test "modules.package exposes core tables" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return type(package), type(package.loaded), type(package.preload), type(package.searchers)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("table")),
        TValue.fromString(try ctx.base.gc().allocString("table")),
        TValue.fromString(try ctx.base.gc().allocString("table")),
        TValue.fromString(try ctx.base.gc().allocString("table")),
    });
}

test "modules.require returns builtin library table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local m = require("string")
        \\return m == string, package.loaded.string == string
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        .{ .boolean = true },
    });
}

test "modules.require uses package.preload and caches the result" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\preload_calls = 0
        \\package.preload.demo_mod = function(name, loader_data)
        \\  preload_calls = preload_calls + 1
        \\  return { name = name, loader = loader_data }
        \\end
        \\local a = require("demo_mod")
        \\local b = require("demo_mod")
        \\return preload_calls, a == b, a.name, a.loader, package.loaded.demo_mod == a
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("demo_mod")),
        TValue.fromString(try ctx.base.gc().allocString(":preload:")),
        .{ .boolean = true },
    });
}

test "modules.require errors when package.searchers is not a table" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\package.searchers = 1
        \\local ok, err = pcall(require, "missing_mod")
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "package.searchers");
            try api.expectStringContains(err_str.asSlice(), "table");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "modules.require reports module not found" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local ok, err = pcall(require, "definitely_missing_module_name")
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "module 'definitely_missing_module_name' not found");
            try api.expectStringContains(err_str.asSlice(), "package.preload");
        },
        else => return error.TestUnexpectedResult,
    }
}
