const std = @import("std");
const testing = std.testing;
const lexer = @import("../compiler/lexer.zig");
const parser = @import("../compiler/parser.zig");
const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const test_utils = @import("test_utils.zig");

fn parseAndExecute(vm: *VM, allocator: std.mem.Allocator, source: []const u8) !VM.ReturnValue {
    var lx = lexer.Lexer.init(source);
    var proto_builder = parser.ProtoBuilder.init(allocator, &vm.gc);
    defer proto_builder.deinit();

    var p = parser.Parser.init(&lx, &proto_builder);
    try p.parseChunk();

    const proto = try proto_builder.toProto(allocator);
    defer allocator.free(proto.code);
    defer allocator.free(proto.k);

    return vm.execute(&proto);
}

// =============================================================================
// Basic local variable tests
// =============================================================================

test "local: single variable" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 10
        \\    return a
        \\end
        \\return test()
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 10 });
}

test "local: two variables return first" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 10
        \\    local b = 20
        \\    return a
        \\end
        \\return test()
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 10 });
}

test "local: two variables return second" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 10
        \\    local b = 20
        \\    return b
        \\end
        \\return test()
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 20 });
}

test "local: expression in initializer" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 10
        \\    local b = 20
        \\    return a + b
        \\end
        \\return test()
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 30 });
}

test "local: computed value" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 10
        \\    local b = 20
        \\    local c = a + b
        \\    return c
        \\end
        \\return test()
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 30 });
}

// =============================================================================
// Local variables with function parameters
// =============================================================================

test "local: with parameter" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function add(x)
        \\    local y = 5
        \\    return x + y
        \\end
        \\return add(10)
    ;
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 15 });
}

test "local: multiple params and locals" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function calc(a, b)
        \\    local sum = a + b
        \\    local diff = a - b
        \\    return sum * diff
        \\end
        \\return calc(10, 3)
    ;
    // sum = 13, diff = 7, result = 91
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 91 });
}

// =============================================================================
// Register allocation correctness
// =============================================================================

test "local: registers not reused incorrectly" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // This was the original bug: local b would reuse local a's register
    const source =
        \\function test()
        \\    local a = 111
        \\    local b = 222
        \\    local c = 333
        \\    return a + b + c
        \\end
        \\return test()
    ;
    // 111 + 222 + 333 = 666
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 666 });
}

test "local: complex expression does not overwrite locals" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\function test()
        \\    local a = 2
        \\    local b = 3
        \\    local c = a * b + a - b
        \\    return c
        \\end
        \\return test()
    ;
    // a=2, b=3
    // 2*3 + 2 - 3 = 6 + 2 - 3 = 5
    const result = try parseAndExecute(&vm, arena.allocator(), source);
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 5 });
}
