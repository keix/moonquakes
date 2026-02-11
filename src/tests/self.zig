const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

test "SELF - prepare method call" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Create a table with a method
    const table = try vm.gc.allocTable();
    const method_key = try vm.gc.allocString("getValue");

    // Create a simple closure as the method
    // (In a real test, this would be a proper closure)
    // For this test, we just verify the SELF instruction sets up registers correctly

    // R[0] = table (object)
    vm.stack[0] = TValue.fromTable(table);

    // Add a method to the table
    try table.set(method_key, .{ .integer = 42 }); // placeholder value as "method"

    const constants = [_]TValue{
        TValue.fromString(method_key), // K[0] = "getValue"
    };

    const code = [_]Instruction{
        // SELF R[1], R[0], K[0]: R[2] := R[0]; R[1] := R[0]["getValue"]
        Instruction.initABC(.SELF, 1, 0, 0),
        Instruction.initABC(.RETURN, 1, 3, 0), // Return R[1], R[2]
    };

    const proto = try test_utils.createTestProto(&vm, &constants, &code, 0, false, 4);

    const result = try Mnemonics.execute(&vm, proto);
    try testing.expect(result == .multiple);

    // R[1] should be the method (42 in our test)
    try testing.expect(result.multiple[0].eql(.{ .integer = 42 }));
    // R[2] should be the object (the table)
    try testing.expect(result.multiple[1].asTable() == table);
}
