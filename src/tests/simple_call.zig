const std = @import("std");
const testing = std.testing;
const VM = @import("../vm/vm.zig").VM;
const Proto = @import("../compiler/proto.zig").Proto;
const TValue = @import("../runtime/value.zig").TValue;
const Closure = @import("../runtime/closure.zig").Closure;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const test_utils = @import("test_utils.zig");

test "closure constant loading" {
    // First, test if we can load a closure constant
    const func_proto = Proto{
        .k = &[_]TValue{},
        .code = &[_]Instruction{},
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    const func_closure = Closure.init(&func_proto);

    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = closure
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_constants = [_]TValue{
        .{ .closure = &func_closure },
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&main_proto);

    try test_utils.ReturnTest.expectSingle(result, .{ .closure = &func_closure });
}

test "simple function call without arguments" {
    // Function that returns 42
    const func_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = 42
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const func_constants = [_]TValue{
        .{ .integer = 42 },
    };
    const func_proto = Proto{
        .k = &func_constants,
        .code = &func_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    // Create closure
    const func_closure = Closure.init(&func_proto);

    // Main function that calls func()
    const main_code = [_]Instruction{
        // Load function closure into R[0]
        Instruction.initABx(.LOADK, 0, 0), // R[0] = closure
        // Call function with no args, expect 1 result
        Instruction.initABC(.CALL, 0, 1, 2), // R[0] = R[0]()
        // Return the result
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_constants = [_]TValue{
        .{ .closure = &func_closure },
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&main_proto);

    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 42 });
}

test "function call with arguments" {
    // Function add(a, b) that returns a + b
    const add_code = [_]Instruction{
        Instruction.initABC(.ADD, 2, 0, 1), // R[2] = R[0] + R[1]
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2]
    };
    const add_proto = Proto{
        .k = &[_]TValue{},
        .code = &add_code,
        .numparams = 2,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    // Create closure
    const add_closure = Closure.init(&add_proto);

    // Main function that calls add(10, 20)
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = add closure
        Instruction.initABx(.LOADK, 1, 1), // R[1] = 10
        Instruction.initABx(.LOADK, 2, 2), // R[2] = 20
        Instruction.initABC(.CALL, 0, 3, 2), // R[0] = R[0](R[1], R[2])
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_constants = [_]TValue{
        .{ .closure = &add_closure },
        .{ .integer = 10 },
        .{ .integer = 20 },
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    const result = try vm.execute(&main_proto);

    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 30 });
}
