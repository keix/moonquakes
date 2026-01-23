const std = @import("std");
const testing = std.testing;
const lexer = @import("../compiler/lexer.zig");
const parser = @import("../compiler/parser.zig");
const VM = @import("../vm/vm.zig").VM;

/// Compile source code and return the maxstacksize
fn compileAndGetMaxStack(allocator: std.mem.Allocator, gc: *@import("../runtime/gc/gc.zig").GC, source: []const u8) !u8 {
    var lx = lexer.Lexer.init(source);
    var proto_builder = parser.ProtoBuilder.init(allocator, gc);
    defer proto_builder.deinit();

    var p = parser.Parser.init(&lx, &proto_builder);
    try p.parseChunk();

    const proto = try proto_builder.toProto(allocator);
    defer allocator.free(proto.code);
    defer allocator.free(proto.k);

    return proto.maxstacksize;
}

/// Generate Lua code with N elseif branches
/// Uses numeric comparisons that the parser supports
fn generateElseifChain(allocator: std.mem.Allocator, n: usize) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("if 1 == 0 then return 0\n");
    for (0..n) |i| {
        try buf.writer().print("elseif {d} == {d} then return {d}\n", .{ i + 1, i + 1, i + 1 });
    }
    try buf.appendSlice("else return 999 end\n");

    return buf.toOwnedSlice();
}

/// Generate Lua code with N sequential function calls
fn generateSequentialCalls(allocator: std.mem.Allocator, n: usize) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (0..n) |i| {
        try buf.writer().print("print({d})\n", .{i});
    }

    return buf.toOwnedSlice();
}

test "register scope: elseif chain does not accumulate registers" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Small chain (10 elseif)
    const small_code = try generateElseifChain(allocator, 10);
    const small_max = try compileAndGetMaxStack(allocator, &vm.gc, small_code);

    // Large chain (100 elseif)
    const large_code = try generateElseifChain(allocator, 100);
    const large_max = try compileAndGetMaxStack(allocator, &vm.gc, large_code);

    // Max stack should be roughly the same (bounded)
    // Without scope guards, large would be ~100+ registers
    // With scope guards, both should be small (~2-4 registers)
    try testing.expect(small_max < 10);
    try testing.expect(large_max < 10);
    try testing.expect(large_max <= small_max + 2); // Allow small variance
}

test "register scope: sequential calls do not accumulate registers" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Small sequence (10 calls)
    const small_code = try generateSequentialCalls(allocator, 10);
    const small_max = try compileAndGetMaxStack(allocator, &vm.gc, small_code);

    // Large sequence (100 calls)
    const large_code = try generateSequentialCalls(allocator, 100);
    const large_max = try compileAndGetMaxStack(allocator, &vm.gc, large_code);

    // Max stack should be roughly the same (bounded)
    // Without scope guards, large would be ~100+ registers
    // With scope guards, both should be small
    try testing.expect(small_max < 10);
    try testing.expect(large_max < 10);
    try testing.expect(large_max <= small_max + 2);
}

test "register scope: for loop body does not accumulate registers" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Single statement in for loop
    const single_stmt =
        \\for i = 1, 10 do
        \\  print(i)
        \\end
    ;
    const single_max = try compileAndGetMaxStack(allocator, &vm.gc, single_stmt);

    // Multiple statements in for loop
    const multi_stmt =
        \\for i = 1, 10 do
        \\  print(i)
        \\  print(i)
        \\  print(i)
        \\  print(i)
        \\  print(i)
        \\end
    ;
    const multi_max = try compileAndGetMaxStack(allocator, &vm.gc, multi_stmt);

    // For loop uses NUMERIC_FOR_REGS (4) registers + temporaries
    // Max stack should be bounded regardless of statement count
    try testing.expect(single_max <= parser.NUMERIC_FOR_REGS + 5);
    try testing.expect(multi_max <= parser.NUMERIC_FOR_REGS + 5);
    try testing.expect(multi_max <= single_max + 2);
}
