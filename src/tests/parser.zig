const std = @import("std");
const testing = std.testing;
const lexer = @import("../compiler/lexer.zig");
const parser = @import("../compiler/parser.zig");
const TValue = @import("../core/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const test_utils = @import("test_utils.zig");

fn parseAndExecute(allocator: std.mem.Allocator, source: []const u8) !VM.ReturnValue {
    var lx = lexer.Lexer.init(source);
    var proto_builder = parser.ProtoBuilder.init(allocator);
    defer proto_builder.deinit();

    var p = parser.Parser.init(&lx, &proto_builder);
    try p.parseChunk();

    const proto = try proto_builder.toProto(allocator);
    defer allocator.free(proto.code);
    defer allocator.free(proto.k);

    var vm = VM.init();
    return vm.execute(&proto);
}

test "parser: return 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 42");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 42 });
}

test "parser: return 1 + 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 1 + 2");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 3 });
}

test "parser: return 2 * 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 2 * 3");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 6 });
}

test "parser: return 1 + 2 * 3 (precedence)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 1 + 2 * 3");
    // Should be 1 + (2 * 3) = 1 + 6 = 7, not (1 + 2) * 3 = 9
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 7 });
}

test "parser: return 2 * 3 + 1 (precedence reverse)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 2 * 3 + 1");
    // Should be (2 * 3) + 1 = 6 + 1 = 7
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 7 });
}

test "parser: return 1 + 2 + 3 (left associative)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 1 + 2 + 3");
    // Should be ((1 + 2) + 3) = (3 + 3) = 6
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 6 });
}

test "parser: return 2 * 3 * 4 (left associative)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 2 * 3 * 4");
    // Should be ((2 * 3) * 4) = (6 * 4) = 24
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 24 });
}

test "parser: return 1 + 2 + 3 * 4 (complex)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 1 + 2 + 3 * 4");
    // Should be ((1 + 2) + (3 * 4)) = (3 + 12) = 15
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 15 });
}

test "parser: return 0 + 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 0 + 0");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 0 });
}

test "parser: return 5 * 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 5 * 0");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 0 });
}

test "parser: return 100 + 200" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 100 + 200");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 300 });
}

test "parser: local x = 42 (unsupported statement)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = parseAndExecute(allocator, "local x = 42");
    try testing.expectError(error.UnsupportedStatement, result);
}

test "parser: return + 5 (unexpected token)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = parseAndExecute(allocator, "return + 5");
    try testing.expectError(error.ExpectedExpression, result);
}

test "parser: return (no expression)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = parseAndExecute(allocator, "return");
    try testing.expectError(error.ExpectedExpression, result);
}

test "parser: return \"hello\" (string literal)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return \"hello\"");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .string = "hello" });
}

test "parser: return 6 / 2 (division)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 6 / 2");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .number = 3.0 });
}

test "parser: return 5 - 3 (subtraction)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, "return 5 - 3");
    try test_utils.ReturnTest.expectSingle(result, TValue{ .integer = 2 });
}
