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

test "modules.package exposes config string and search helpers" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\return type(package.config), type(package.searchpath), type(package.loadlib)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("string")),
        TValue.fromString(try ctx.base.gc().allocString("function")),
        TValue.fromString(try ctx.base.gc().allocString("function")),
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

test "modules.package searchpath finds module path with default separators" {
    const module_path = "tmp_api_pkg_search/module.lua";
    try std.fs.cwd().makePath("tmp_api_pkg_search");
    defer std.fs.cwd().deleteFile(module_path) catch {};
    defer std.fs.cwd().deleteDir("tmp_api_pkg_search") catch {};
    try writeFixture(module_path, "return true");

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local path = assert(package.searchpath("module", "./tmp_api_pkg_search/?.lua"))
        \\return path
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("./tmp_api_pkg_search/module.lua", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "modules.package searchpath reports searched paths on failure" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local path, err = package.searchpath("foo.bar", "./?.lua;./?/init.lua")
        \\return path, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0] == .nil);
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "./foo/bar.lua");
            try api.expectStringContains(err_str.asSlice(), "./foo/bar/init.lua");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "modules.package searchpath supports custom separator and replacement" {
    const module_path = "tmp-api-pkg-custom-foo.lua";
    defer deleteFixture(module_path);
    try writeFixture(module_path, "return true");

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local path = assert(package.searchpath("tmp_api_pkg_custom_foo", "./?.lua", "_", "-"))
        \\return path
    );

    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("./tmp-api-pkg-custom-foo.lua", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "modules.package loadlib reports unsupported C loader contract" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local f, msg, where = package.loadlib("libdemo.so", "luaopen_demo")
        \\return f, msg, where
    );

    try api.expectMultiple(result, &[_]TValue{
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("C libraries not supported")),
        TValue.fromString(try ctx.base.gc().allocString("absent")),
    });
}

test "modules.require caches true when preload loader returns nil" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local calls = 0
        \\package.preload.nilmod = function()
        \\  calls = calls + 1
        \\end
        \\local a = require("nilmod")
        \\local b = require("nilmod")
        \\return calls, a, b, package.loaded.nilmod
    );

    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 1 },
        .{ .boolean = true },
        .{ .boolean = true },
        .{ .boolean = true },
    });
}

test "modules.require loads Lua modules through package.path" {
    const module_name = "tmp_api_require_module";
    const module_path = "tmp_api_require_module.lua";
    try writeFixture(module_path, "return { value = 42, label = 'loaded' }");
    defer deleteFixture(module_path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\package.path = "./?.lua"
        \\local m, loader = require("{s}")
        \\return m.value, m.label, package.loaded["{s}"] == m, loader
    ,
        .{ module_name, module_name },
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectMultiple(result, &[_]TValue{
        .{ .integer = 42 },
        TValue.fromString(try ctx.base.gc().allocString("loaded")),
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("./tmp_api_require_module.lua")),
    });
}

test "modules.require rejects non-string package.path" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\package.path = {}
        \\local ok, err = pcall(require, "still_missing")
        \\return ok, err
    );

    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expect(values[0].eql(.{ .boolean = false }));
            const err_str = values[1].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err_str.asSlice(), "package.path must be a string");
        },
        else => return error.TestUnexpectedResult,
    }
}
