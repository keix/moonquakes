const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const Mnemonics = @import("../vm/mnemonics.zig");
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

const test_utils = @import("test_utils.zig");

test "SETLIST basic - set array elements" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Create a table
    const table = try ctx.vm.gc().allocTable();
    ctx.vm.stack[0] = TValue.fromTable(table);
    // Values to set
    ctx.vm.stack[1] = .{ .integer = 10 };
    ctx.vm.stack[2] = .{ .integer = 20 };
    ctx.vm.stack[3] = .{ .integer = 30 };

    const code = [_]Instruction{
        // SETLIST R0, 3, 1: set table[1]=R1, table[2]=R2, table[3]=R3
        Instruction.initABC(.SETLIST, 0, 3, 1),
        Instruction.initABC(.RETURN, 0, 2, 0), // return table
    };

    const proto = try test_utils.createTestProto(ctx.vm, &.{}, &code, 0, false, 5);

    const result = try Mnemonics.execute(ctx.vm, proto);
    try testing.expect(result == .single);

    // Check table contents (SETLIST now uses integer keys)
    const result_table = result.single.asTable().?;

    const v1 = result_table.get(TValue{ .integer = 1 }).?;
    const v2 = result_table.get(TValue{ .integer = 2 }).?;
    const v3 = result_table.get(TValue{ .integer = 3 }).?;

    try testing.expect(v1.eql(.{ .integer = 10 }));
    try testing.expect(v2.eql(.{ .integer = 20 }));
    try testing.expect(v3.eql(.{ .integer = 30 }));
}

test "SETLIST with B=0 - variable count from top" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Create a table
    const table = try ctx.vm.gc().allocTable();
    ctx.vm.stack[0] = TValue.fromTable(table);
    // Values to set
    ctx.vm.stack[1] = .{ .integer = 100 };
    ctx.vm.stack[2] = .{ .integer = 200 };
    ctx.vm.top = 3; // Set top to indicate 2 values

    const code = [_]Instruction{
        // SETLIST R0, 0, 1: B=0 means use top, set table[1]=R1, table[2]=R2
        Instruction.initABC(.SETLIST, 0, 0, 1),
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &.{}, &code, 0, false, 5);

    const result = try Mnemonics.execute(ctx.vm, proto);
    try testing.expect(result == .single);

    const result_table = result.single.asTable().?;

    const v1 = result_table.get(TValue{ .integer = 1 }).?;
    const v2 = result_table.get(TValue{ .integer = 2 }).?;

    try testing.expect(v1.eql(.{ .integer = 100 }));
    try testing.expect(v2.eql(.{ .integer = 200 }));
}

test "SETLIST with offset mode (k=1, C=0)" {
    var ctx: test_utils.TestContext = undefined;
    try ctx.init();
    defer ctx.deinit();

    // Create a table with first element already set (using integer key)
    const table = try ctx.vm.gc().allocTable();
    try table.set(TValue{ .integer = 1 }, .{ .integer = 1 });

    ctx.vm.stack[0] = TValue.fromTable(table);
    // Values to set starting at index 2
    ctx.vm.stack[1] = .{ .integer = 2 };
    ctx.vm.stack[2] = .{ .integer = 3 };
    ctx.vm.top = 3;

    const code = [_]Instruction{
        // SETLIST with k=1, C=0, EXTRAARG=2: start at index 2
        Instruction.initABCk(.SETLIST, 0, 0, 0, true),
        Instruction.initAx(.EXTRAARG, 2), // start_index = 2
        Instruction.initABC(.RETURN, 0, 2, 0),
    };

    const proto = try test_utils.createTestProto(ctx.vm, &.{}, &code, 0, false, 5);

    const result = try Mnemonics.execute(ctx.vm, proto);
    try testing.expect(result == .single);

    const result_table = result.single.asTable().?;

    // Original index 1 should be preserved
    const v1 = result_table.get(TValue{ .integer = 1 }).?;
    try testing.expect(v1.eql(.{ .integer = 1 }));

    // New values at indices 2 and 3
    const v2 = result_table.get(TValue{ .integer = 2 }).?;
    const v3 = result_table.get(TValue{ .integer = 3 }).?;
    try testing.expect(v2.eql(.{ .integer = 2 }));
    try testing.expect(v3.eql(.{ .integer = 3 }));
}
