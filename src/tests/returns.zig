const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectNoResult(result: ReturnValue) !void {
    try testing.expect(result == .none);
}

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn expectMultipleResults(result: ReturnValue, expected: []const TValue) !void {
    try testing.expect(result == .multiple);
    try testing.expectEqual(expected.len, result.multiple.len);
    for (expected, result.multiple) |exp, actual| {
        try testing.expect(exp.eql(actual));
    }
}

test "return: no values (RETURN with B=1)" {
    const code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = Proto{
        .k = &[_]TValue{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectNoResult(result);
}

test "return: single value (RETURN with B=2)" {
    const constants = [_]TValue{
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}

test "return: multiple values (RETURN with B=4)" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 3
        Instruction.initABC(.RETURN, 0, 4, 0), // return R0, R1, R2 (B=4 means 3 values)
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    const expected = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    try expectMultipleResults(result, &expected);
}

test "return: RETURN0 - no values" {
    const code = [_]Instruction{
        Instruction.initABC(.RETURN0, 0, 0, 0), // return nothing
    };

    const proto = Proto{
        .k = &[_]TValue{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try testing.expect(result == .none);
}

test "return: RETURN1 - single value" {
    const constants = [_]TValue{
        .{ .integer = 42 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R0
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 42 });
}
