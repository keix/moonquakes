const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const object = @import("../runtime/gc/object.zig");

const test_utils = @import("test_utils.zig");

fn createTableWithAddMM(vm: *VM, value: i64) !*object.TableObject {
    const table = try vm.gc.allocTable();

    // Create metatable with __add
    const mt = try vm.gc.allocTable();
    const add_key = try vm.gc.allocString("__add");

    // Create a simple native closure that adds values
    // For testing, we'll use a Lua closure instead
    const inner_code = [_]Instruction{
        // R0 = self, R1 = other
        // Return self.value + other (or other + self.value)
        Instruction.initABC(.RETURN, 0, 2, 0), // simplified - just return first arg
    };

    _ = inner_code;

    // Store value in table
    const value_key = try vm.gc.allocString("value");
    try table.set(value_key, .{ .integer = value }, &vm.gc);

    // Set metatable (simplified - full test would need closure)
    table.metatable = mt;
    _ = add_key;

    return table;
}

test "MMBINI - add with immediate (basic structure)" {
    // This test verifies the MMBINI opcode structure
    // Full metamethod testing requires more complex setup
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Test that MMBINI with non-table value raises error
    vm.stack[0] = .{ .integer = 10 };

    const code = [_]Instruction{
        // MMBINI A=0, sB=5, C=6 (add event), k=0 (R[A] + sB)
        Instruction.initABC(.MMBINI, 0, 5, 6), // C=6 is add event
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = try test_utils.createTestProto(&vm, &.{}, &code, 0, false, 3);

    // Should fail because integer has no __add metamethod
    const result = Mnemonics.execute(&vm, proto);
    try testing.expectError(error.ArithmeticError, result);
}

test "MMBINK - add with constant (basic structure)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    const constants = [_]TValue{
        .{ .integer = 100 },
    };

    // Test that MMBINK with non-table value raises error
    vm.stack[0] = .{ .integer = 10 };

    const code = [_]Instruction{
        // MMBINK A=0, B=0 (constant index), C=6 (add event), k=0 (R[A] + K[B])
        Instruction.initABC(.MMBINK, 0, 0, 6), // C=6 is add event
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 3);

    // Should fail because integer has no __add metamethod
    const result = Mnemonics.execute(&vm, proto);
    try testing.expectError(error.ArithmeticError, result);
}

test "MMBINI operand order with k flag" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // With k=0: R[A] op sB
    // With k=1: sB op R[A]
    // Both should fail for integers (no metamethod)

    vm.stack[0] = .{ .integer = 10 };

    // k=0: R[0] + 5, C=6 (add event)
    const code_k0 = [_]Instruction{
        Instruction.initABCk(.MMBINI, 0, 5, 6, false),
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto_k0 = try test_utils.createTestProto(&vm, &.{}, &code_k0, 0, false, 3);

    try testing.expectError(error.ArithmeticError, Mnemonics.execute(&vm, proto_k0));

    // k=1: 5 + R[0], C=6 (add event)
    const code_k1 = [_]Instruction{
        Instruction.initABCk(.MMBINI, 0, 5, 6, true),
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto_k1 = try test_utils.createTestProto(&vm, &.{}, &code_k1, 0, false, 3);

    try testing.expectError(error.ArithmeticError, Mnemonics.execute(&vm, proto_k1));
}
