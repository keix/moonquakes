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

/// Compile source to RawProto (no GC needed)
pub fn compile(allocator: std.mem.Allocator, source: []const u8) !RawProto {
    var lx = lexer.Lexer.init(source);
    var builder = parser.ProtoBuilder.init(allocator, null);
    defer builder.deinit();

    var p = parser.Parser.init(&lx, &builder);
    defer p.deinit();
    try p.parseChunk();

    return try builder.toRawProto(allocator, 0);
}

/// Free RawProto and all nested protos
pub fn freeRawProto(allocator: std.mem.Allocator, raw: RawProto) void {
    allocator.free(raw.code);
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
