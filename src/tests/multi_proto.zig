const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const Proto = @import("../vm/func.zig").Proto;
const TValue = @import("../core/value.zig").TValue;
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

    const Closure = @import("../core/closure.zig").Closure;

    // Proto for add function
    const add_code = [_]Instruction{
        // R[0] = a, R[1] = b (parameters)
        Instruction.initABC(.ADD, 2, 0, 1), // R[2] = R[0] + R[1]
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2] (1 value)
    };

    const add_proto = Proto{
        .k = &[_]TValue{},
        .code = &add_code,
        .numparams = 2,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    const add_closure = Closure.init(&add_proto);

    // Proto for main function
    const main_constants = [_]TValue{
        .{ .closure = &add_closure },
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

    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    // Test execution with real function call
    var vm = VM.init();
    const result = try vm.execute(&main_proto);

    // Should return 10 + 20 = 30
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 30 });
}

test "VM call stack push and pop" {
    var vm = VM.init();

    // Create test protos
    const proto1_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const proto1 = Proto{
        .k = &[_]TValue{},
        .code = &proto1_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    const proto2_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const proto2 = Proto{
        .k = &[_]TValue{},
        .code = &proto2_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    // Set up initial call frame (simulating execute)
    vm.base_ci = .{
        .func = &proto1,
        .pc = proto1.code.ptr,
        .base = 0,
        .ret_base = 0,
        .savedpc = null,
        .nresults = -1,
        .previous = null,
    };
    vm.ci = &vm.base_ci;
    vm.base = 0;

    // Test pushing a new call frame
    const new_ci = try vm.pushCallFrame(&proto2, 4, 4, 1);
    try std.testing.expect(vm.ci == new_ci);
    try std.testing.expect(vm.base == 4);
    try std.testing.expect(vm.callstack_size == 1);
    try std.testing.expect(new_ci.previous == &vm.base_ci);
    try std.testing.expect(new_ci.func == &proto2);
    try std.testing.expect(new_ci.nresults == 1);

    // Test popping call frame
    vm.popCallFrame();
    try std.testing.expect(vm.ci == &vm.base_ci);
    try std.testing.expect(vm.base == 0);
    try std.testing.expect(vm.callstack_size == 0);
}

test "VM call stack overflow" {
    var vm = VM.init();

    const dummy_code = [_]Instruction{
        Instruction.initABC(.RETURN, 0, 1, 0),
    };
    const dummy_proto = Proto{
        .k = &[_]TValue{},
        .code = &dummy_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    // Set up initial frame
    vm.base_ci = .{
        .func = &dummy_proto,
        .pc = dummy_proto.code.ptr,
        .base = 0,
        .ret_base = 0,
        .savedpc = null,
        .nresults = -1,
        .previous = null,
    };
    vm.ci = &vm.base_ci;

    // Push frames until we hit the limit
    var i: usize = 0;
    while (i < vm.callstack.len) : (i += 1) {
        _ = try vm.pushCallFrame(&dummy_proto, @intCast(i * 4), @intCast(i * 4), 1);
    }

    // Next push should fail
    try std.testing.expectError(error.CallStackOverflow, vm.pushCallFrame(&dummy_proto, 100, 100, 1));
}
