const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../core/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const OpCode = opcodes.OpCode;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn expectMultipleResults(result: VM.ReturnValue, expected: []const TValue) !void {
    try testing.expect(result == .multiple);
    try testing.expectEqual(expected.len, result.multiple.len);
    for (expected, result.multiple) |e, r| {
        try testing.expect(e.eql(r));
    }
}

test "LOADBOOL: load true" {
    const code = [_]Instruction{
        Instruction.initABC(.LOADBOOL, 0, 1, 0), // R0 = true, no skip
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
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

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "LOADBOOL: load false" {
    const code = [_]Instruction{
        Instruction.initABC(.LOADBOOL, 0, 0, 0), // R0 = false, no skip
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
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

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "LOADBOOL: with skip" {
    const code = [_]Instruction{
        Instruction.initABC(.LOADBOOL, 0, 1, 1), // R0 = true, skip next
        Instruction.initABC(.LOADBOOL, 0, 0, 0), // This should be skipped
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0 (should be true)
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

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "LOADNIL: single register" {
    const constants = [_]TValue{
        .{ .integer = 42 }, // Some initial value
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 42
        Instruction.initABC(.LOADNIL, 0, 0, 0), // R0 = nil (B=0 means only R[A])
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

    try expectSingleResult(result, TValue.nil);
}

test "LOADNIL: multiple registers" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 1, 1), // R1 = 2
        Instruction.initABx(.LOADK, 2, 2), // R2 = 3
        Instruction.initABC(.LOADNIL, 0, 2, 0), // R0, R1, R2 = nil (B=2 means R[A]..R[A+2])
        Instruction.initABC(.RETURN, 0, 4, 0), // return R0, R1, R2
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

    const expected = [_]TValue{ .nil, .nil, .nil };
    try expectMultipleResults(result, &expected);
}

test "LOADNIL: range in middle of stack" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initABx(.LOADK, 4, 1), // R4 = 5
        Instruction.initABC(.LOADNIL, 1, 2, 0), // R1, R2, R3 = nil
        Instruction.initABC(.RETURN, 0, 6, 0), // return R0, R1, R2, R3, R4
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    const expected = [_]TValue{
        .{ .integer = 1 },
        .nil,
        .nil,
        .nil,
        .{ .integer = 5 },
    };
    try expectMultipleResults(result, &expected);
}
