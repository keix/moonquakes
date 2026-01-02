const std = @import("std");
const testing = std.testing;

const TValue = @import("../runtime/value.zig").TValue;
const VM = @import("../vm/vm.zig").VM;
const lexer = @import("../compiler/lexer.zig");
const parser = @import("../compiler/parser.zig");

fn expectSingleResult(result: VM.ReturnValue, expected: TValue) !void {
    try testing.expect(result == .single);
    try testing.expect(result.single.eql(expected));
}

fn parseAndExecute(allocator: std.mem.Allocator, source: []const u8) !VM.ReturnValue {
    var lx = lexer.Lexer.init(source);
    var proto_builder = parser.ProtoBuilder.init(allocator);
    defer proto_builder.deinit();

    var p = parser.Parser.init(&lx, &proto_builder);
    try p.parseChunk();

    const proto = try proto_builder.toProto(allocator);
    defer allocator.free(proto.code);
    defer allocator.free(proto.k);

    var vm = try VM.init(testing.allocator);
    defer vm.deinit();
    return vm.execute(&proto);
}

fn testParserExpression(source: []const u8, expected: TValue) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try parseAndExecute(allocator, source);

    try expectSingleResult(result, expected);
    // Ensure result is never nil (critical check)
    try testing.expect(!result.single.isNil());
}

test "parser comparison: == operator with equal values" {
    try testParserExpression("return 5 == 5", TValue{ .boolean = true });
}

test "parser comparison: == operator with different values" {
    try testParserExpression("return 5 == 3", TValue{ .boolean = false });
}

test "parser comparison: != operator with equal values" {
    try testParserExpression("return 5 != 5", TValue{ .boolean = false });
}

test "parser comparison: != operator with different values" {
    try testParserExpression("return 5 != 3", TValue{ .boolean = true });
}

test "parser comparison: complex arithmetic with ==" {
    try testParserExpression("return 3 % 3 == 0", TValue{ .boolean = true });
}

test "parser comparison: complex arithmetic false case should not return nil" {
    try testParserExpression("return 4 % 3 == 0", TValue{ .boolean = false });
}

test "parser comparison: != operator edge case that was returning nil" {
    // This was the specific case that returned nil before our fix
    try testParserExpression("return 5 != 3", TValue{ .boolean = true });
}

test "parser comparison: zero comparisons" {
    const testCases = [_]struct {
        source: []const u8,
        expected: bool,
    }{
        .{ .source = "return 0 == 0", .expected = true },
        .{ .source = "return 0 != 0", .expected = false },
        .{ .source = "return 1 == 0", .expected = false },
        .{ .source = "return 1 != 0", .expected = true },
    };

    for (testCases) |case| {
        try testParserExpression(case.source, TValue{ .boolean = case.expected });
    }
}

test "parser comparison: modulo edge cases" {
    const testCases = [_]struct {
        source: []const u8,
        expected: bool,
    }{
        .{ .source = "return 15 % 15 == 0", .expected = true },
        .{ .source = "return 1 % 15 == 0", .expected = false },
        .{ .source = "return 3 % 3 == 0", .expected = true },
        .{ .source = "return 4 % 3 == 0", .expected = false },
        .{ .source = "return 5 % 5 == 0", .expected = true },
        .{ .source = "return 6 % 5 == 0", .expected = false },
        .{ .source = "return 15 % 3 == 0", .expected = true },
        .{ .source = "return 15 % 5 == 0", .expected = true },
    };

    for (testCases) |case| {
        try testParserExpression(case.source, TValue{ .boolean = case.expected });
    }
}

test "parser comparison: chained operations" {
    // Test more complex expressions that could break comparison logic
    try testParserExpression("return 2 + 3 == 5", TValue{ .boolean = true });
    try testParserExpression("return 2 * 3 != 5", TValue{ .boolean = true });
    try testParserExpression("return 10 / 2 == 5", TValue{ .boolean = true });
    try testParserExpression("return 7 % 3 == 1", TValue{ .boolean = true });
}

test "parser comparison: negative numbers" {
    try testParserExpression("return 0 - 5 == 0 - 5", TValue{ .boolean = true });
    try testParserExpression("return 0 - 3 != 0 - 5", TValue{ .boolean = true });
}
