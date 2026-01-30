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

test "parser: return 42" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 42");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });
}

test "parser: return 1 + 2" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 1 + 2");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 3 });
}

test "parser: return 2 * 3" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 2 * 3");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 6 });
}

test "parser: return 1 + 2 * 3 (precedence)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 1 + 2 * 3");
    // Should be 1 + (2 * 3) = 1 + 6 = 7, not (1 + 2) * 3 = 9
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 7 });
}

test "parser: return 2 * 3 + 1 (precedence reverse)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 2 * 3 + 1");
    // Should be (2 * 3) + 1 = 6 + 1 = 7
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 7 });
}

test "parser: return 1 + 2 + 3 (left associative)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 1 + 2 + 3");
    // Should be ((1 + 2) + 3) = (3 + 3) = 6
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 6 });
}

test "parser: return 2 * 3 * 4 (left associative)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 2 * 3 * 4");
    // Should be ((2 * 3) * 4) = (6 * 4) = 24
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 24 });
}

test "parser: return 1 + 2 + 3 * 4 (complex)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 1 + 2 + 3 * 4");
    // Should be ((1 + 2) + (3 * 4)) = (3 + 12) = 15
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 15 });
}

test "parser: return 0 + 0" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 0 + 0");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 0 });
}

test "parser: return 5 * 0" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 5 * 0");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 0 });
}

test "parser: return 100 + 200" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 100 + 200");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 300 });
}

test "parser: local x = 42" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator,
        \\local x = 42
        \\return x
    );
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });
}

test "parser: return + 5 (unexpected token)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = parseAndExecute(&vm, allocator, "return + 5");
    try testing.expectError(error.ExpectedExpression, result);
}

test "parser: return (no expression)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = parseAndExecute(&vm, allocator, "return");
    try testing.expectError(error.ExpectedExpression, result);
}

test "parser: return \"hello\" (string literal)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return \"hello\"");
    // Verify result is a single string value
    try testing.expect(result == .single);
    try testing.expect(result.single.isString());
    // Verify string content matches
    const actual_str = result.single.string.asSlice();
    try testing.expectEqualStrings("hello", actual_str);
}

test "parser: return 6 / 2 (division)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 6 / 2");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .number = 3.0 });
}

test "parser: return 5 - 3 (subtraction)" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator, "return 5 - 3");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 2 });
}

test "parser: local variable assignment" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator,
        \\local x = 10
        \\x = 20
        \\return x
    );
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 20 });
}

test "parser: local variable assignment with expression" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator,
        \\local x = 5
        \\x = x + 10
        \\return x
    );
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 15 });
}

test "parser: table field assignment" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator,
        \\local t = {}
        \\t.x = 42
        \\return t.x
    );
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });
}

test "parser: table nested field assignment" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(&vm, allocator,
        \\local t = { inner = {} }
        \\t.inner.value = 100
        \\return t.inner.value
    );
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 100 });
}
