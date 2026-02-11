const std = @import("std");
const testing = std.testing;
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const TValue = @import("../runtime/value.zig").TValue;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const OpCode = @import("../compiler/opcodes.zig").OpCode;
const test_utils = @import("test_utils.zig");

test "manual multi-proto execution - simple call and return" {
    // Now we can actually test multi-proto with real function calls!
    // function add(a, b)
    //     return a + b
    // end
    //
    // function main()
    //     local x = 10
    //     local y = 20
    //     local z = add(x, y)
    //     return z
    // end

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Proto for add function
    const add_code = [_]Instruction{
        // R[0] = a, R[1] = b (parameters)
        Instruction.initABC(.ADD, 2, 0, 1), // R[2] = R[0] + R[1]
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2] (1 value)
    };

    const add_proto = try test_utils.createTestProto(&vm, &[_]TValue{}, &add_code, 2, false, 3);

    // Create closure via GC
    const add_closure = try vm.gc.allocClosure(add_proto);

    // Proto for main function - build constants at runtime
    var main_constants = [_]TValue{
        TValue.fromClosure(add_closure),
        .{ .integer = 10 },
        .{ .integer = 20 },
    };

    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = add closure
        Instruction.initABx(.LOADK, 1, 1), // R[1] = 10
        Instruction.initABx(.LOADK, 2, 2), // R[2] = 20
        Instruction.initABC(.CALL, 0, 3, 2), // R[0] = add(R[1], R[2])
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    const main_proto = try test_utils.createTestProto(&vm, &main_constants, &main_code, 0, false, 4);

    // Capture initial state
    var trace = test_utils.ExecutionTrace.captureInitial(&vm, 4);

    const result = try Mnemonics.execute(&vm, main_proto);

    // Update final state
    trace.updateFinal(&vm, 4);

    // Should return 10 + 20 = 30
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 30 });

    // Verify register states
    // R[0] should contain the result (30)
    try trace.expectRegisterChanged(0, .{ .integer = 30 });
}

test "VM call stack push and pop" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Create test protos via GC
    const proto1_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const proto1 = try test_utils.createTestProto(&vm, &[_]TValue{}, &proto1_code, 0, false, 1);

    const proto2_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const proto2 = try test_utils.createTestProto(&vm, &[_]TValue{}, &proto2_code, 0, false, 1);

    // Set up initial call frame (simulating execute)
    vm.base_ci = .{
        .func = proto1,
        .closure = null,
        .pc = proto1.code.ptr,
        .savedpc = null,
        .base = 0,
        .ret_base = 0,
        .nresults = -1,
        .previous = null,
    };
    vm.ci = &vm.base_ci;
    vm.base = 0;

    // Test pushing a new call info (null closure since we're testing with bare Proto)
    const new_ci = try Mnemonics.pushCallInfo(&vm, proto2, null, 4, 4, 1);
    try std.testing.expect(vm.ci == new_ci);
    try std.testing.expect(vm.base == 4);
    try std.testing.expect(vm.callstack_size == 1);
    try std.testing.expect(new_ci.previous == &vm.base_ci);
    try std.testing.expect(new_ci.func == proto2);
    try std.testing.expect(new_ci.nresults == 1);
    try std.testing.expect(new_ci.ret_base == 4);

    // Verify base and pc are set correctly
    try std.testing.expect(new_ci.base == 4);
    try std.testing.expect(new_ci.pc == proto2.code.ptr);

    // Test popping call info
    const old_base = vm.base;
    const old_ci = vm.ci;
    Mnemonics.popCallInfo(&vm);

    // Verify state after pop
    try std.testing.expect(vm.ci == &vm.base_ci);
    try std.testing.expect(vm.base == 0);
    try std.testing.expect(vm.callstack_size == 0);

    // Verify old_ci is still valid but no longer current
    try std.testing.expect(old_ci == &vm.callstack[0]);
    try std.testing.expect(old_base == 4);
}

test "VM call stack overflow" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const dummy_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const dummy_proto = try test_utils.createTestProto(&vm, &[_]TValue{}, &dummy_code, 0, false, 1);

    // Set up initial frame
    vm.base_ci = .{
        .func = dummy_proto,
        .closure = null,
        .pc = dummy_proto.code.ptr,
        .savedpc = null,
        .base = 0,
        .ret_base = 0,
        .nresults = -1,
        .previous = null,
    };
    vm.ci = &vm.base_ci;

    // Push frames until we hit the limit
    var i: usize = 0;
    while (i < vm.callstack.len) : (i += 1) {
        _ = try Mnemonics.pushCallInfo(&vm, dummy_proto, null, @intCast(i * 4), @intCast(i * 4), 1);
    }

    // Next push should fail
    try std.testing.expectError(error.CallStackOverflow, Mnemonics.pushCallInfo(&vm, dummy_proto, null, 100, 100, 1));
}

test "nested function call with register tracking" {
    // Test a deeper call: main -> add -> multiply

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // multiply(a, b) returns a * b
    const mul_code = [_]Instruction{
        Instruction.initABC(.MUL, 2, 0, 1), // R[2] = R[0] * R[1]
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2]
    };
    const mul_proto = try test_utils.createTestProto(&vm, &[_]TValue{}, &mul_code, 2, false, 3);

    // Create closures via GC
    const mul_closure = try vm.gc.allocClosure(mul_proto);

    // add_and_double(a, b) returns (a + b) * 2
    const add_double_code = [_]Instruction{
        Instruction.initABC(.ADD, 2, 0, 1), // R[2] = R[0] + R[1]
        Instruction.initABx(.LOADK, 3, 0), // R[3] = mul_closure
        Instruction.initABx(.LOADK, 4, 1), // R[4] = R[2] (sum)
        Instruction.initABx(.LOADK, 5, 2), // R[5] = 2
        Instruction.initABC(.MOVE, 4, 2, 0), // R[4] = R[2] (sum)
        Instruction.initABC(.CALL, 3, 3, 2), // R[3] = mul(R[4], R[5])
        Instruction.initABC(.RETURN, 3, 2, 0), // return R[3]
    };
    var add_double_constants = [_]TValue{
        TValue.fromClosure(mul_closure),
        .{ .integer = 0 }, // placeholder
        .{ .integer = 2 },
    };
    const add_double_proto = try test_utils.createTestProto(&vm, &add_double_constants, &add_double_code, 2, false, 6);
    const add_double_closure = try vm.gc.allocClosure(add_double_proto);

    // main: add_and_double(3, 4)
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = add_double_closure
        Instruction.initABx(.LOADK, 1, 1), // R[1] = 3
        Instruction.initABx(.LOADK, 2, 2), // R[2] = 4
        Instruction.initABC(.CALL, 0, 3, 2), // R[0] = add_double(3, 4)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    var main_constants = [_]TValue{
        TValue.fromClosure(add_double_closure),
        .{ .integer = 3 },
        .{ .integer = 4 },
    };
    const main_proto = try test_utils.createTestProto(&vm, &main_constants, &main_code, 0, false, 3);

    // Track call stack depth
    try std.testing.expect(vm.callstack_size == 0);

    const result = try Mnemonics.execute(&vm, main_proto);

    // (3 + 4) * 2 = 14
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 14 });

    // Verify call stack was properly cleaned up
    try std.testing.expect(vm.callstack_size == 0);
    try std.testing.expect(vm.ci == &vm.base_ci);
}
