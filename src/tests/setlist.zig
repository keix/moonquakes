const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

test "SETLIST basic - set array elements" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Create a table
    const table = try vm.gc.allocTable();
    vm.stack[0] = TValue.fromTable(table);
    // Values to set
    vm.stack[1] = .{ .integer = 10 };
    vm.stack[2] = .{ .integer = 20 };
    vm.stack[3] = .{ .integer = 30 };

    const code = [_]Instruction{
        // SETLIST R0, 3, 1: set table[1]=R1, table[2]=R2, table[3]=R3
        Instruction.initABC(.SETLIST, 0, 3, 1),
        Instruction.initABC(.RETURN, 0, 2, 0), // return table
    };

    const proto = Proto{
        .k = &.{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    const result = try Mnemonics.execute(&vm, &proto);
    try testing.expect(result == .single);

    // Check table contents
    const result_table = result.single.asTable().?;
    const key1 = try vm.gc.allocString("1");
    const key2 = try vm.gc.allocString("2");
    const key3 = try vm.gc.allocString("3");

    const v1 = result_table.get(key1).?;
    const v2 = result_table.get(key2).?;
    const v3 = result_table.get(key3).?;

    try testing.expect(v1.eql(.{ .integer = 10 }));
    try testing.expect(v2.eql(.{ .integer = 20 }));
    try testing.expect(v3.eql(.{ .integer = 30 }));
}

test "SETLIST with B=0 - variable count from top" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Create a table
    const table = try vm.gc.allocTable();
    vm.stack[0] = TValue.fromTable(table);
    // Values to set
    vm.stack[1] = .{ .integer = 100 };
    vm.stack[2] = .{ .integer = 200 };
    vm.top = 3; // Set top to indicate 2 values

    const code = [_]Instruction{
        // SETLIST R0, 0, 1: B=0 means use top, set table[1]=R1, table[2]=R2
        Instruction.initABC(.SETLIST, 0, 0, 1),
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = Proto{
        .k = &.{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    const result = try Mnemonics.execute(&vm, &proto);
    try testing.expect(result == .single);

    const result_table = result.single.asTable().?;
    const key1 = try vm.gc.allocString("1");
    const key2 = try vm.gc.allocString("2");

    const v1 = result_table.get(key1).?;
    const v2 = result_table.get(key2).?;

    try testing.expect(v1.eql(.{ .integer = 100 }));
    try testing.expect(v2.eql(.{ .integer = 200 }));
}

test "SETLIST with offset mode (k=1, C=0)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // Create a table with first element already set
    const table = try vm.gc.allocTable();
    const key1 = try vm.gc.allocString("1");
    try table.set(key1, .{ .integer = 1 });

    vm.stack[0] = TValue.fromTable(table);
    // Values to set starting at index 2
    vm.stack[1] = .{ .integer = 2 };
    vm.stack[2] = .{ .integer = 3 };
    vm.top = 3;

    const code = [_]Instruction{
        // SETLIST with k=1, C=0, EXTRAARG=2: start at index 2
        Instruction.initABCk(.SETLIST, 0, 0, 0, true),
        Instruction.initAx(.EXTRAARG, 2), // start_index = 2
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = Proto{
        .k = &.{},
        .code = &code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 5,
    };

    const result = try Mnemonics.execute(&vm, &proto);
    try testing.expect(result == .single);

    const result_table = result.single.asTable().?;
    const key2 = try vm.gc.allocString("2");
    const key3 = try vm.gc.allocString("3");

    // Original index 1 should be preserved
    const v1 = result_table.get(key1).?;
    try testing.expect(v1.eql(.{ .integer = 1 }));

    // New values at indices 2 and 3
    const v2 = result_table.get(key2).?;
    const v3 = result_table.get(key3).?;
    try testing.expect(v2.eql(.{ .integer = 2 }));
    try testing.expect(v3.eql(.{ .integer = 3 }));
}
