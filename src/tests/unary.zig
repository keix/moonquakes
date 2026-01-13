const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "unary: -5 = -5" {
    const constants = [_]TValue{
        .{ .integer = 5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABC(.UNM, 1, 0, 0), // R1 = -R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = -5 });
}

test "unary: -3.5 = -3.5" {
    const constants = [_]TValue{
        .{ .number = 3.5 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 3.5
        Instruction.initABC(.UNM, 1, 0, 0), // R1 = -R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .number = -3.5 });
}

test "unary: not true = false" {
    const constants = [_]TValue{
        .{ .boolean = true },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = true
        Instruction.initABC(.NOT, 1, 0, 0), // R1 = not R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "unary: not nil = true" {
    const constants = [_]TValue{
        .nil,
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = nil
        Instruction.initABC(.NOT, 1, 0, 0), // R1 = not R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = true });
}

test "unary: not 0 = false" {
    const constants = [_]TValue{
        .{ .integer = 0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0
        Instruction.initABC(.NOT, 1, 0, 0), // R1 = not R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .boolean = false });
}

test "unary: -5 + 3 = -2" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 3 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 3
        Instruction.initABC(.UNM, 2, 0, 0), // R2 = -R0 = -5
        Instruction.initABC(.ADD, 3, 2, 1), // R3 = R2 + R1 = -5 + 3
        Instruction.initABC(.RETURN, 3, 2, 0), // return R3
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = -2 });
}

test "unary: #\"hello\" = 5 (string length)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Allocate string through GC
    const hello_str = try vm.gc.allocString("hello");

    const constants = [_]TValue{
        .{ .string = hello_str },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = "hello"
        Instruction.initABC(.LEN, 1, 0, 0), // R1 = #R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 5 });
}

test "unary: #\"\" = 0 (empty string length)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Allocate empty string through GC
    const empty_str = try vm.gc.allocString("");

    const constants = [_]TValue{
        .{ .string = empty_str },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = ""
        Instruction.initABC(.LEN, 1, 0, 0), // R1 = #R0
        Instruction.initABC(.RETURN, 1, 2, 0), // return R1
    };

    const proto = Proto{
        .k = &constants,
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    const result = try vm.execute(&proto);

    try expectSingleResult(result, TValue{ .integer = 0 });
}
