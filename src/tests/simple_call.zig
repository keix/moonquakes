const std = @import("std");
const testing = std.testing;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const TValue = @import("../runtime/value.zig").TValue;
const ClosureObject = @import("../runtime/gc/object.zig").ClosureObject;
const GC = @import("../runtime/gc/gc.zig").GC;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const test_utils = @import("test_utils.zig");

test "closure constant loading" {
    // First, test if we can load a closure constant
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const func_proto = try test_utils.createTestProto(&vm, &[_]TValue{}, &[_]Instruction{}, 0, false, 1);

    // Create closure via GC
    const func_closure = try vm.gc.allocClosure(func_proto);

    // Build constants at runtime
    var main_constants = [_]TValue{
        TValue.fromClosure(func_closure),
    };

    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = closure
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_proto = try test_utils.createTestProto(&vm, &main_constants, &main_code, 0, false, 1);

    const result = try Mnemonics.execute(&vm, main_proto);

    try test_utils.ReturnTest.expectSingle(result, TValue.fromClosure(func_closure));
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

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const func_proto = try test_utils.createTestProto(&vm, &func_constants, &func_code, 0, false, 1);

    // Create closure via GC
    const func_closure = try vm.gc.allocClosure(func_proto);

    // Build constants at runtime
    var main_constants = [_]TValue{
        TValue.fromClosure(func_closure),
    };

    // Main function that calls func()
    const main_code = [_]Instruction{
        // Load function closure into R[0]
        Instruction.initABx(.LOADK, 0, 0), // R[0] = closure
        // Call function with no args, expect 1 result
        Instruction.initABC(.CALL, 0, 1, 2), // R[0] = R[0]()
        // Return the result
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_proto = try test_utils.createTestProto(&vm, &main_constants, &main_code, 0, false, 2);

    const result = try Mnemonics.execute(&vm, main_proto);

    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 42 });
}

test "function call with arguments" {
    // Function add(a, b) that returns a + b
    const add_code = [_]Instruction{
        Instruction.initABC(.ADD, 2, 0, 1), // R[2] = R[0] + R[1]
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2]
    };

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const add_proto = try test_utils.createTestProto(&vm, &[_]TValue{}, &add_code, 2, false, 3);

    // Create closure via GC
    const add_closure = try vm.gc.allocClosure(add_proto);

    // Build constants at runtime
    var main_constants = [_]TValue{
        TValue.fromClosure(add_closure),
        .{ .integer = 10 },
        .{ .integer = 20 },
    };

    // Main function that calls add(10, 20)
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = add closure
        Instruction.initABx(.LOADK, 1, 1), // R[1] = 10
        Instruction.initABx(.LOADK, 2, 2), // R[2] = 20
        Instruction.initABC(.CALL, 0, 3, 2), // R[0] = R[0](R[1], R[2])
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_proto = try test_utils.createTestProto(&vm, &main_constants, &main_code, 0, false, 3);

    const result = try Mnemonics.execute(&vm, main_proto);

    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 30 });
}
