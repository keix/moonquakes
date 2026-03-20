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

test "os clock time and difftime expose numeric time contracts" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local c1 = os.clock()
        \\local now = os.time()
        \\local c2 = os.clock()
        \\return type(c1), type(now), c2 >= c1, os.difftime(10, 3)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("number")),
        TValue.fromString(try ctx.base.gc().allocString("number")),
        .{ .boolean = true },
        .{ .number = 7.0 },
    });
}

test "os date formats and time table normalization follow Lua contracts" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local iso = os.date("!%Y-%m-%d %H:%M:%S", 0)
        \\local dt = os.date("!*t", 0)
        \\local t = { year = 2024, month = 13, day = 1, hour = 0, min = 0, sec = 0 }
        \\local ts = os.time(t)
        \\return iso, dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec, ts, t.year, t.month, t.day
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("1970-01-01 00:00:00")),
        .{ .integer = 1970 },
        .{ .integer = 1 },
        .{ .integer = 1 },
        .{ .integer = 0 },
        .{ .integer = 0 },
        .{ .integer = 0 },
        .{ .integer = 1735689600 },
        .{ .integer = 2025 },
        .{ .integer = 1 },
        .{ .integer = 1 },
    });
}

test "os tmpname and getenv return host-visible values" {
    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const result = try ctx.exec(
        \\local tmp = os.tmpname()
        \\local missing = os.getenv("MOONQUAKES_API_TEST_MISSING_ENV")
        \\local path = os.getenv("PATH")
        \\return type(tmp), string.sub(tmp, 1, 5), missing, type(path)
    );

    try api.expectMultiple(result, &[_]TValue{
        TValue.fromString(try ctx.base.gc().allocString("string")),
        TValue.fromString(try ctx.base.gc().allocString("/tmp/")),
        .nil,
        TValue.fromString(try ctx.base.gc().allocString("string")),
    });
}

test "os rename and remove operate on filesystem paths" {
    const source_path = "tmp_api_os_source.txt";
    const renamed_path = "tmp_api_os_renamed.txt";
    try writeFixture(source_path, "payload");
    defer deleteFixture(source_path);
    defer deleteFixture(renamed_path);

    var ctx = api.ApiContext{};
    try ctx.init();
    defer ctx.deinit();

    const source = try std.fmt.allocPrint(
        testing.allocator,
        \\local ok1 = os.rename("{s}", "{s}")
        \\local ok2 = os.remove("{s}")
        \\local ok3, err3 = os.remove("{s}")
        \\return ok1, ok2, ok3, err3
    ,
        .{ source_path, renamed_path, renamed_path, renamed_path },
    );
    defer testing.allocator.free(source);

    const result = try ctx.exec(source);
    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(@as(usize, 4), values.len);
            try testing.expect(values[0].eql(.{ .boolean = true }));
            try testing.expect(values[1].eql(.{ .boolean = true }));
            try testing.expect(values[2] == .nil);
            const err = values[3].asString() orelse return error.TestUnexpectedResult;
            try api.expectStringContains(err.asSlice(), "No such file or directory");
        },
        else => return error.TestUnexpectedResult,
    }
}
