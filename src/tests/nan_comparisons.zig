const std = @import("std");
const testing = std.testing;

const TValue = @import("../core/value.zig").TValue;
const Proto = @import("../core/proto.zig").Proto;
const VM = @import("../vm/vm.zig").VM;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

test "LT with NaN: NaN < 5.0 = false" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = nan },
        .{ .number = 5.0 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = NaN
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5.0
        Instruction.initABC(.LT, 0, 0, 1), // if (R0 < R1) != 0 then skip next (if less than then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than)
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
    const result = try vm.execute(&proto);

    // NaN < 5.0 should be false in Lua
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "LT with NaN: 5.0 < NaN = false" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = 5.0 },
        .{ .number = nan },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = 5.0
        Instruction.initABx(.LOADK, 1, 1), // R1 = NaN
        Instruction.initABC(.LT, 0, 0, 1), // if (R0 < R1) != 0 then skip next
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than)
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
    const result = try vm.execute(&proto);

    // 5.0 < NaN should be false in Lua
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "LE with NaN: NaN <= 5.0 = false" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = nan },
        .{ .number = 5.0 },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = NaN
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5.0
        Instruction.initABC(.LE, 0, 0, 1), // if (R0 <= R1) != 0 then skip next
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than or equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than or equal)
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
    const result = try vm.execute(&proto);

    // NaN <= 5.0 should be false in Lua
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "LE with NaN: NaN <= NaN = false" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = nan },
        .{ .number = nan },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = NaN
        Instruction.initABx(.LOADK, 1, 1), // R1 = NaN
        Instruction.initABC(.LE, 0, 0, 1), // if (R0 <= R1) != 0 then skip next
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not less than or equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if less than or equal)
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
    const result = try vm.execute(&proto);

    // NaN <= NaN should be false in Lua
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "EQ with NaN: NaN == NaN = false" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = nan },
        .{ .number = nan },
        .{ .boolean = true }, // result for true case
        .{ .boolean = false }, // result for false case
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = NaN
        Instruction.initABx(.LOADK, 1, 1), // R1 = NaN
        Instruction.initABC(.EQ, 0, 0, 1), // if (R0 == R1) != 0 then skip next (if equal then skip)
        Instruction.initABx(.LOADK, 2, 3), // R2 = false (executed if not equal)
        Instruction.initsJ(.JMP, 1), // Jump to return
        Instruction.initABx(.LOADK, 2, 2), // R2 = true (executed if equal)
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
    const result = try vm.execute(&proto);

    // NaN == NaN should be false
    try expectSingleResult(result, TValue{ .boolean = false });
}

test "Arithmetic with NaN propagation" {
    const nan = std.math.nan(f64);
    const constants = [_]TValue{
        .{ .number = nan },
        .{ .number = 5.0 },
    };

    const code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R0 = NaN
        Instruction.initABx(.LOADK, 1, 1), // R1 = 5.0
        Instruction.initABC(.ADD, 2, 0, 1), // R2 = R0 + R1 (NaN + 5.0 = NaN)
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
    const result = try vm.execute(&proto);

    // NaN + 5.0 should propagate NaN
    try testing.expect(result == .single);
    try testing.expect(result.single == .number);
    try testing.expect(std.math.isNan(result.single.number));
}
