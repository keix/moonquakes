//! Compiler Pipeline
//!
//! Compilation stages: source -> RawProto -> ProtoObject
//! - RawProto: intermediate representation (no GC dependencies)
//! - ProtoObject: GC-managed bytecode (strings allocated via GC)

const std = @import("std");
const proto_mod = @import("proto.zig");
const RawProto = proto_mod.RawProto;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
pub const materialize = @import("materialize.zig").materialize;

/// Compilation error with structured information
pub const CompileError = struct {
    line: u32,
    message: []const u8, // Allocated by provided allocator

    pub fn deinit(self: *const CompileError, allocator: std.mem.Allocator) void {
        if (self.message.len > 0) {
            allocator.free(self.message);
        }
    }
};

/// Result of compilation: either success with RawProto or error with details
pub const CompileResult = union(enum) {
    ok: RawProto,
    err: CompileError,

    pub fn deinit(self: *CompileResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |raw| freeRawProto(allocator, raw),
            .err => |*e| e.deinit(allocator),
        }
    }
};

/// Compilation options
pub const CompileOptions = struct {
    source_name: []const u8 = "[string]",
};

/// Compile source to RawProto or CompileError
///
/// Pure function - no side effects, no GC dependencies.
/// Caller must handle the result and call deinit when done.
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: CompileOptions,
) CompileResult {
    var lx = lexer.Lexer.init(source);
    var builder = parser.ProtoBuilder.init(allocator, null) catch {
        return .{ .err = .{ .line = 0, .message = allocator.dupe(u8, "OutOfMemory") catch "" } };
    };
    builder.source = options.source_name;
    // Note: _ENV upvalue is now added in ProtoBuilder.init for all functions

    defer builder.deinit();

    var p = parser.Parser.init(&lx, &builder);
    defer p.deinit();

    p.parseChunk() catch |err| {
        const line: u32 = @intCast(p.current.line);
        const parser_msg = p.getErrorMsg();

        const message = if (parser_msg.len > 0)
            allocator.dupe(u8, parser_msg) catch ""
        else
            allocator.dupe(u8, @errorName(err)) catch "";

        return .{ .err = .{ .line = line, .message = message } };
    };

    const raw = builder.toRawProto(allocator, 0) catch |err| {
        const message = allocator.dupe(u8, @errorName(err)) catch "";
        return .{ .err = .{ .line = 0, .message = message } };
    };

    return .{ .ok = raw };
}

/// Free RawProto and all nested protos
pub fn freeRawProto(allocator: std.mem.Allocator, raw: RawProto) void {
    allocator.free(raw.code);
    allocator.free(raw.lineinfo);
    allocator.free(raw.source);
    allocator.free(raw.booleans);
    allocator.free(raw.integers);
    allocator.free(raw.numbers);
    for (raw.strings) |s| {
        allocator.free(s);
    }
    allocator.free(raw.strings);
    allocator.free(raw.native_ids);
    allocator.free(raw.const_refs);
    for (raw.protos) |nested| {
        freeRawProto(allocator, nested.*);
        allocator.destroy(@constCast(nested));
    }
    allocator.free(raw.protos);
    allocator.free(raw.upvalues);
}

// Note: freeProto removed - ProtoObject is now GC-managed
// GC handles freeing ProtoObject and its internal arrays during sweep
