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

test "io.type distinguishes file handles from ordinary values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local f = io.output()
        \\return io.type(f), io.type({}), io.type(nil)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("file")),
        .nil,
        .nil,
    });
}

test "io.open read mode exposes file type and read formats" {
    const path = "tmp_api_io_read.txt";
    try writeFixture(path, "alpha\nbeta\n");
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local f = assert(io.open("{s}", "r"))
        \\local kind = io.type(f)
        \\local first = f:read("*l")
        \\local rest = f:read("*a")
        \\local closed = f:close()
        \\return kind, first, rest, closed, io.type(f)
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("file")),
        TValue.fromString(try ctx.base.gc().allocString("alpha")),
        TValue.fromString(try ctx.base.gc().allocString("beta\n")),
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("closed file")),
    });
}

test "io.open write mode persists writes on close" {
    const path = "tmp_api_io_write.txt";
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local f = assert(io.open("{s}", "w"))
        \\local chained = f:write("hello", "-", 42) == f
        \\local before = io.type(f)
        \\local closed = f:close()
        \\return chained, before, closed, io.type(f)
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectMultiple(result, &[_]TValue{
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("file")),
        .{ .boolean = true },
        TValue.fromString(try ctx.base.gc().allocString("closed file")),
    });

    const written = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("hello-42", written);
}

test "io.lines iterates over file contents by filename" {
    const path = "tmp_api_io_lines.txt";
    try writeFixture(path, "red\ngreen\nblue\n");
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local out = {{}}
        \\for line in io.lines("{s}") do
        \\  out[#out + 1] = line
        \\end
        \\return table.concat(out, ",")
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    switch (result) {
        .single => |value| {
            const s = value.asString() orelse return error.TestUnexpectedResult;
            try testing.expectEqualStrings("red,green,blue", s.asSlice());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "file lines iterator reads successive lines from an open handle" {
    const path = "tmp_api_file_lines.txt";
    try writeFixture(path, "one\ntwo\n");
    defer deleteFixture(path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local f = assert(io.open("{s}", "r"))
        \\local iter = f:lines()
        \\local a = iter()
        \\local b = iter()
        \\local c = iter()
        \\f:close()
        \\return a, b, c, io.type(f)
    ,
        .{path},
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("one")),
        TValue.fromString(try ctx.base.gc().allocString("two")),
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("closed file")),
    });
}
