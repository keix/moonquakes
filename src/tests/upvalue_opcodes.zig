const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const object = @import("../runtime/gc/object.zig");
const Upvaldesc = object.Upvaldesc;
const ProtoObject = object.ProtoObject;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const test_utils = @import("test_utils.zig");

test "CLOSE opcode - no-op behavior" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Initialize some registers
    ctx.vm.stack[0] = .{ .integer = 42 };
    ctx.vm.stack[1] = .{ .number = 3.14 };
    ctx.vm.stack[2] = .{ .boolean = true };

    const inst = Instruction.initABC(.CLOSE, 1, 0, 0); // close from R[1] upward

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &code, 0, false, 3);

    const initial_trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 3);

    const result = try Mnemonics.execute(&ctx.vm, proto);
    try test_utils.ReturnTest.expectNone(result);

    var final_trace = initial_trace;
    final_trace.updateFinal(&ctx.vm, 3);

    // CLOSE should be a no-op for now - all registers should be unchanged
    try final_trace.expectRegisterUnchanged(0);
    try final_trace.expectRegisterUnchanged(1);
    try final_trace.expectRegisterUnchanged(2);
}

test "TBC opcode - nil value (no-op)" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Initialize registers - nil is a valid TBC target that does nothing
    ctx.vm.stack[0] = .{ .integer = 42 };
    ctx.vm.stack[1] = .nil; // nil doesn't require __close

    const inst = Instruction.initABC(.TBC, 1, 0, 0); // mark R[1] as to-be-closed

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    try testing.expect(result == .single);
    try testing.expect(result.single.eql(.{ .integer = 42 }));
}

test "TBC opcode - false value (no-op)" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // false is also a valid TBC target that does nothing
    ctx.vm.stack[0] = .{ .integer = 100 };
    ctx.vm.stack[1] = .{ .boolean = false };

    const inst = Instruction.initABC(.TBC, 1, 0, 0); // mark R[1] as to-be-closed

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);

    try testing.expect(result == .single);
    try testing.expect(result.single.eql(.{ .integer = 100 }));
}

test "SETUPVAL opcode - no-op behavior" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Initialize some registers
    ctx.vm.stack[0] = .{ .integer = 123 };
    ctx.vm.stack[1] = .{ .boolean = false };

    const inst = Instruction.initABC(.SETUPVAL, 0, 1, 0); // UpValue[1] := R[0]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &[_]TValue{}, &code, 0, false, 3);

    const initial_trace = test_utils.ExecutionTrace.captureInitial(&ctx.vm, 3);

    const result = try Mnemonics.execute(&ctx.vm, proto);
    try test_utils.ReturnTest.expectNone(result);

    var final_trace = initial_trace;
    final_trace.updateFinal(&ctx.vm, 3);

    // SETUPVAL should be a no-op for now - all registers should be unchanged
    try final_trace.expectRegisterUnchanged(0);
    try final_trace.expectRegisterUnchanged(1);
    try final_trace.expectRegisterUnchanged(2);
}

test "SETTABUP opcode - global variable assignment" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate string through GC
    const myvar_str = try ctx.vm.gc.allocString("myvar");

    // Create constant for variable name
    const constants = [_]TValue{
        TValue.fromString(myvar_str), // K[0]
    };

    // Initialize register with value to set
    ctx.vm.stack[1] = .{ .integer = 42 };

    const inst = Instruction.initABC(.SETTABUP, 0, 0, 1); // _ENV[K[0]] := R[1]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    try test_utils.ReturnTest.expectNone(result);

    // Verify the global variable was set
    const global_val = ctx.vm.globals.get(TValue.fromString(myvar_str)).?;
    try testing.expect(global_val.eql(.{ .integer = 42 }));
}

test "SETTABUP opcode - multiple global assignments" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate strings through GC
    const var1_str = try ctx.vm.gc.allocString("var1");
    const var2_str = try ctx.vm.gc.allocString("var2");
    const var3_str = try ctx.vm.gc.allocString("var3");

    // Create constants for variable names
    const constants = [_]TValue{
        TValue.fromString(var1_str), // K[0]
        TValue.fromString(var2_str), // K[1]
        TValue.fromString(var3_str), // K[2]
    };

    // Initialize registers with values to set
    ctx.vm.stack[0] = .{ .integer = 10 };
    ctx.vm.stack[1] = .{ .number = 3.14 };
    ctx.vm.stack[2] = .{ .boolean = true };

    const code = [_]Instruction{
        Instruction.initABC(.SETTABUP, 0, 0, 0), // _ENV[K[0]] := R[0]
        Instruction.initABC(.SETTABUP, 0, 1, 1), // _ENV[K[1]] := R[1]
        Instruction.initABC(.SETTABUP, 0, 2, 2), // _ENV[K[2]] := R[2]
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    try test_utils.ReturnTest.expectNone(result);

    // Verify all global variables were set correctly
    const var1 = ctx.vm.globals.get(TValue.fromString(var1_str)).?;
    const var2 = ctx.vm.globals.get(TValue.fromString(var2_str)).?;
    const var3 = ctx.vm.globals.get(TValue.fromString(var3_str)).?;

    try testing.expect(var1.eql(.{ .integer = 10 }));
    try testing.expect(var2.eql(.{ .number = 3.14 }));
    try testing.expect(var3.eql(.{ .boolean = true }));
}

test "SETTABUP opcode - invalid key type" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Create constant with non-string key
    const constants = [_]TValue{
        .{ .integer = 123 }, // K[0] - invalid key type
    };

    ctx.vm.stack[1] = .{ .integer = 42 };

    const inst = Instruction.initABC(.SETTABUP, 0, 0, 1); // _ENV[K[0]] := R[1]

    const code = [_]Instruction{
        inst,
        Instruction.initABC(.RETURN, 0, 1, 0),
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);

    // Should fail with InvalidTableKey error
    const result = Mnemonics.execute(&ctx.vm, proto);
    try testing.expectError(error.InvalidTableKey, result);
}

test "All new opcodes - integration test" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Allocate string through GC
    const result_str = try ctx.vm.gc.allocString("result");

    const constants = [_]TValue{
        TValue.fromString(result_str), // K[0]
    };

    // Initialize registers
    ctx.vm.stack[0] = .{ .integer = 999 };
    ctx.vm.stack[1] = .{ .number = 2.71 };
    ctx.vm.stack[2] = .nil; // TBC target (nil is valid without __close)

    const code = [_]Instruction{
        // Test all four new opcodes in sequence
        Instruction.initABC(.CLOSE, 1, 0, 0), // close from R[1] upward (no-op)
        Instruction.initABC(.TBC, 2, 0, 0), // mark R[2] (nil) as to-be-closed
        Instruction.initABC(.SETUPVAL, 1, 0, 0), // UpValue[0] := R[1] (no-op)
        Instruction.initABC(.SETTABUP, 0, 0, 0), // _ENV[K[0]] := R[0] (sets global)
        Instruction.initABC(.RETURN, 0, 1, 0), // return nothing
    };

    const proto = try test_utils.createTestProto(&ctx.vm, &constants, &code, 0, false, 3);
    const result = try Mnemonics.execute(&ctx.vm, proto);
    try test_utils.ReturnTest.expectNone(result);

    // Only SETTABUP should have side effects
    const global_val = ctx.vm.globals.get(TValue.fromString(result_str)).?;
    try testing.expect(global_val.eql(.{ .integer = 999 }));
}

test "CLOSURE opcode - create closure without upvalues" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Child proto: simple function that returns 42
    const child_code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 42), // R[0] := 42
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R[0]
    };

    const child_proto = try test_utils.createTestProtoWithUpvalues(&ctx.vm, &[_]TValue{}, &child_code, 0, false, 1, 0, &[_]Upvaldesc{});

    // Parent proto: create closure and return it
    const parent_code = [_]Instruction{
        Instruction.initABx(.CLOSURE, 0, 0), // R[0] := closure(KPROTO[0])
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R[0]
    };

    const parent_proto = try test_utils.createTestProtoWithChildProtos(&ctx.vm, &[_]TValue{}, &parent_code, 0, false, 1, &[_]*ProtoObject{child_proto});

    const result = try Mnemonics.execute(&ctx.vm, parent_proto);

    // Should return a closure
    switch (result) {
        .single => |val| {
            try testing.expect(val.isClosure());
            const closure = val.asClosure().?;
            try testing.expectEqual(child_proto, closure.proto);
            try testing.expectEqual(@as(usize, 0), closure.upvalues.len);
        },
        else => return error.UnexpectedResult,
    }
}

test "CLOSURE opcode - create closure with upvalue from stack" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Child proto: function that reads upvalue
    // function() return upval end
    const child_code = [_]Instruction{
        Instruction.initABC(.GETUPVAL, 0, 0, 0), // R[0] := UpValue[0]
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R[0]
    };

    const child_upvalues = [_]Upvaldesc{
        .{ .instack = true, .idx = 0 }, // capture parent's R[0]
    };

    const child_proto = try test_utils.createTestProtoWithUpvalues(&ctx.vm, &[_]TValue{}, &child_code, 0, false, 1, 1, &child_upvalues);

    // Parent proto:
    // local x = 100
    // local f = function() return x end
    // return f
    const parent_code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 100), // R[0] := 100 (local x)
        Instruction.initABx(.CLOSURE, 1, 0), // R[1] := closure(KPROTO[0])
        Instruction.initABC(.RETURN1, 1, 0, 0), // return R[1]
    };

    const parent_proto = try test_utils.createTestProtoWithChildProtos(&ctx.vm, &[_]TValue{}, &parent_code, 0, false, 2, &[_]*ProtoObject{child_proto});

    const result = try Mnemonics.execute(&ctx.vm, parent_proto);

    // Should return a closure with one upvalue
    switch (result) {
        .single => |val| {
            try testing.expect(val.isClosure());
            const closure = val.asClosure().?;
            try testing.expectEqual(child_proto, closure.proto);
            try testing.expectEqual(@as(usize, 1), closure.upvalues.len);

            // The upvalue should point to the value 100
            const upval = closure.upvalues[0];
            try testing.expect(upval.get().eql(.{ .integer = 100 }));
        },
        else => return error.UnexpectedResult,
    }
}

test "CLOSE opcode - closes open upvalues" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Child proto: function that reads upvalue
    const child_code = [_]Instruction{
        Instruction.initABC(.GETUPVAL, 0, 0, 0), // R[0] := UpValue[0]
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R[0]
    };

    const child_upvalues = [_]Upvaldesc{
        .{ .instack = true, .idx = 0 }, // capture parent's R[0]
    };

    const child_proto = try test_utils.createTestProtoWithUpvalues(&ctx.vm, &[_]TValue{}, &child_code, 0, false, 1, 1, &child_upvalues);

    // Parent proto:
    // local x = 200
    // local f = function() return x end
    // close upvalues from R[0]
    // return f
    const parent_code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 200), // R[0] := 200 (local x)
        Instruction.initABx(.CLOSURE, 1, 0), // R[1] := closure(KPROTO[0])
        Instruction.initABC(.CLOSE, 0, 0, 0), // close upvalues from R[0]
        Instruction.initABC(.RETURN1, 1, 0, 0), // return R[1]
    };

    const parent_proto = try test_utils.createTestProtoWithChildProtos(&ctx.vm, &[_]TValue{}, &parent_code, 0, false, 2, &[_]*ProtoObject{child_proto});

    const result = try Mnemonics.execute(&ctx.vm, parent_proto);

    switch (result) {
        .single => |val| {
            try testing.expect(val.isClosure());
            const closure = val.asClosure().?;
            const upval = closure.upvalues[0];

            // After CLOSE, the upvalue should be closed
            try testing.expect(upval.isClosed());

            // The closed value should still be 200
            try testing.expect(upval.get().eql(.{ .integer = 200 }));
        },
        else => return error.UnexpectedResult,
    }

    // VM's open_upvalues list should be empty after CLOSE
    try testing.expect(ctx.vm.open_upvalues == null);
}

test "GETUPVAL and SETUPVAL with closure" {
    var ctx = try test_utils.TestContext.init();
    ctx.fixup();
    defer ctx.deinit();

    // Child proto: function that modifies upvalue and returns it
    // function() upval = upval + 1; return upval end
    const child_code = [_]Instruction{
        Instruction.initABC(.GETUPVAL, 0, 0, 0), // R[0] := UpValue[0]
        Instruction.initAsBx(.ADDI, 0, 1), // R[0] := R[0] + 1
        Instruction.initABC(.MMBIN, 0, 0, 6), // metamethod hint (ADD)
        Instruction.initABC(.SETUPVAL, 0, 0, 0), // UpValue[0] := R[0]
        Instruction.initABC(.RETURN1, 0, 0, 0), // return R[0]
    };

    const child_upvalues = [_]Upvaldesc{
        .{ .instack = true, .idx = 0 }, // capture parent's R[0]
    };

    const child_proto = try test_utils.createTestProtoWithUpvalues(&ctx.vm, &[_]TValue{}, &child_code, 0, false, 1, 1, &child_upvalues);

    // Parent proto:
    // local x = 10
    // local f = function() x = x + 1; return x end
    // return f
    const parent_code = [_]Instruction{
        Instruction.initAsBx(.LOADI, 0, 10), // R[0] := 10 (local x)
        Instruction.initABx(.CLOSURE, 1, 0), // R[1] := closure(KPROTO[0])
        Instruction.initABC(.RETURN1, 1, 0, 0), // return R[1]
    };

    const parent_proto = try test_utils.createTestProtoWithChildProtos(&ctx.vm, &[_]TValue{}, &parent_code, 0, false, 2, &[_]*ProtoObject{child_proto});

    const result = try Mnemonics.execute(&ctx.vm, parent_proto);

    switch (result) {
        .single => |val| {
            try testing.expect(val.isClosure());
            const closure = val.asClosure().?;
            const upval = closure.upvalues[0];

            // Initial value should be 10
            try testing.expect(upval.get().eql(.{ .integer = 10 }));
        },
        else => return error.UnexpectedResult,
    }
}
