const std = @import("std");
const testing = std.testing;

const pipeline = @import("../../compiler/pipeline.zig");
const TValue = @import("../../runtime/value.zig").TValue;
const ReturnValue = @import("../../vm/execution.zig").ReturnValue;
const Mnemonics = @import("../../vm/mnemonics.zig");
const test_utils = @import("../test_utils.zig");

pub const ApiContext = struct {
    base: test_utils.TestContext = undefined,

    pub fn init(self: *ApiContext) !void {
        try self.base.init();
    }

    pub fn deinit(self: *ApiContext) void {
        self.base.deinit();
    }

    pub fn exec(self: *ApiContext, source: []const u8) !ReturnValue {
        const compile_result = self.base.rt.compile_ctx.compile(source, .{ .source_name = "=(api-test)" });
        switch (compile_result) {
            .err => |e| {
                defer e.deinit(self.base.gc().allocator);
                return error.UnexpectedCompileError;
            },
            .ok => {},
        }

        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(self.base.gc().allocator, raw_proto);

        self.base.gc().inhibitGC();
        defer self.base.gc().allowGC();

        const proto = try pipeline.materialize(&raw_proto, self.base.gc(), self.base.gc().allocator);
        return try Mnemonics.execute(self.base.vm, proto);
    }

    pub fn execExpectLuaException(self: *ApiContext, source: []const u8) ![]const u8 {
        const result = self.exec(source);
        try testing.expectError(error.LuaException, result);
        const err_str = self.base.vm.lua_error_value.asString() orelse return error.TestUnexpectedResult;
        return err_str.asSlice();
    }

    pub fn getGlobal(self: *ApiContext, name: []const u8) !?TValue {
        const key = try self.base.gc().allocString(name);
        return self.base.vm.globals().get(TValue.fromString(key));
    }
};

pub fn expectSingleInteger(result: ReturnValue, expected: i64) !void {
    try testing.expect(result == .single);
    try testing.expectEqual(expected, result.single.integer);
}

pub fn expectMultiple(result: ReturnValue, expected: []const TValue) !void {
    switch (result) {
        .multiple => |values| {
            try testing.expectEqual(expected.len, values.len);
            for (expected, values) |exp, got| {
                try testing.expect(got.eql(exp));
            }
        },
        .single => |value| {
            try testing.expectEqual(@as(usize, 1), expected.len);
            try testing.expect(value.eql(expected[0]));
        },
        .none => return error.TestUnexpectedResult,
    }
}

pub fn expectStringContains(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
