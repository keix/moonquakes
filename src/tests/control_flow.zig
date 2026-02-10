const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectSingleResult(result: ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "control flow: JMP forward" {
    const constants = [_]TValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 1
        Instruction.initsJ(.JMP, 1), // Jump over next instruction
        Instruction.initABx(.LOADK, 0, 1), // R0 = 2 (skipped)
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 1 });
}

test "control flow: JMP 0 goes to next instruction" {
    const constants = [_]TValue{
        .{ .integer = 0 },
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    // Test JMP relative offset: sJ=0 should go to next instruction
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0 (counter)
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1 (increment)
        // Loop start (index 2)
        Instruction.initABC(.ADD, 0, 0, 1), // R0 = R0 + R1
        Instruction.initsJ(.JMP, 0), // Jump to next instruction (RETURN)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 1 });
}

test "control flow: JMP out of bounds should error" {
    const constants = [_]TValue{
        .{ .integer = 0 },
    };

    // Test JMP that goes out of bounds
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 0
        Instruction.initsJ(.JMP, 2), // Jump 2 instructions forward (out of bounds)
        Instruction.initABC(.RETURN, 0, 2, 0), // return R0 (never reached)
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
    const result = Mnemonics.execute(&vm, &proto);

    try testing.expectError(error.PcOutOfRange, result);
}

test "control flow: JMP backward (real loop)" {
    const constants = [_]TValue{
        .{ .integer = 0 }, // counter
        .{ .integer = 1 }, // increment
        .{ .integer = 3 }, // limit
    };

    // Real backward loop with condition
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // 0: R0 = 0 (counter)
        Instruction.initABx(.LOADK, 1, 1), // 1: R1 = 1 (increment)
        Instruction.initABx(.LOADK, 2, 2), // 2: R2 = 3 (limit)
        // Loop start (index 3)
        Instruction.initABC(.ADD, 0, 0, 1), // 3: R0 += R1
        Instruction.initABC(.LT, 0, 0, 2), // 4: if R0 < R2 then skip next
        Instruction.initsJ(.JMP, 1), // 5: jump to return (exit loop)
        Instruction.initsJ(.JMP, -4), // 6: jump back to ADD (continue loop)
        Instruction.initABC(.RETURN, 0, 2, 0), // 7: return R0
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 3 });
}

test "control flow: TEST with true value" {
    const constants = [_]TValue{
        .{ .boolean = true },
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = true
        Instruction.initABCk(.TEST, 0, 0, 0, false), // if R0 == false then skip next
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1 (not skipped because R0 != false)
        Instruction.initABx(.LOADK, 1, 2), // R1 = 2
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 2 });
}

test "control flow: TEST with false value" {
    const constants = [_]TValue{
        .{ .boolean = false },
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = false
        Instruction.initABCk(.TEST, 0, 0, 0, false), // if R0 == false then skip next
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1 (skipped)
        Instruction.initABx(.LOADK, 1, 2), // R1 = 2
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 2 });
}

test "control flow: TEST with k=true (inverted)" {
    const constants = [_]TValue{
        .{ .boolean = false },
        .{ .integer = 1 },
        .{ .integer = 2 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = false
        Instruction.initABCk(.TEST, 0, 0, 0, true), // if R0 == true then skip next
        Instruction.initABx(.LOADK, 1, 1), // R1 = 1 (not skipped because R0 != true)
        Instruction.initABx(.LOADK, 1, 2), // R1 = 2
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 2 });
}

test "control flow: TESTSET with true value" {
    const constants = [_]TValue{
        .{ .boolean = true },
        .{ .integer = 99 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = true
        Instruction.initABx(.LOADK, 1, 1), // R1 = 99
        Instruction.initABCk(.TESTSET, 1, 0, 0, false), // if R0 == false then R1 = R0, skip next
        Instruction.initABx(.LOADK, 1, 1), // R1 = 99 (not skipped because R0 != false)
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
    const result = try Mnemonics.execute(&vm, &proto);

    // TESTSET should not have copied, R1 is replaced with 99 again
    try expectSingleResult(result, TValue{ .integer = 99 });
}

test "control flow: if-then-else simulation" {
    const constants = [_]TValue{
        .{ .integer = 5 },
        .{ .integer = 10 },
        .{ .integer = 100 },
        .{ .integer = 200 },
    };

    // Simulate: if (5 < 10) then return 100 else return 200
    // Using new LT semantics: LT A B C means "if (R[B] < R[C]) != A then skip next"
    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5
        Instruction.initABx(.LOADK, 1, 1), // R1 = 10
        Instruction.initABC(.LT, 0, 0, 1), // if (R0 < R1) != 0 (i.e., if (5 < 10) != false) then skip next
        // Since 5 < 10 is true, and true != false, skip the JMP (go to then branch)
        Instruction.initsJ(.JMP, 2), // Jump to else branch (this will be skipped)
        // Then branch (executed because JMP is skipped)
        Instruction.initABx(.LOADK, 2, 2), // R2 = 100
        Instruction.initsJ(.JMP, 1), // Jump to end
        // Else branch
        Instruction.initABx(.LOADK, 2, 3), // R2 = 200
        // End
        Instruction.initABC(.RETURN, 2, 2, 0), // return R2
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
    const result = try Mnemonics.execute(&vm, &proto);

    try expectSingleResult(result, TValue{ .integer = 100 });
}
