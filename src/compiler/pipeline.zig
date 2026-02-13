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
    return compileWithSource(allocator, source, "[string]", null);
}

/// Compile source to RawProto with optional error message output
/// If error_msg_out is provided and compilation fails, it will contain the error message
pub fn compileWithError(allocator: std.mem.Allocator, source: []const u8, error_msg_out: ?*[256]u8) !RawProto {
    return compileWithSource(allocator, source, "[string]", error_msg_out);
}

/// Compile source with source name and optional error output
pub fn compileWithSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_name: []const u8,
    error_msg_out: ?*[256]u8,
) !RawProto {
    var lx = lexer.Lexer.init(source);
    var builder = parser.ProtoBuilder.init(allocator, null);
    builder.source = source_name;
    defer builder.deinit();

    var p = parser.Parser.init(&lx, &builder);
    defer p.deinit();
    p.parseChunk() catch |err| {
        // Copy error message if output buffer provided
        if (error_msg_out) |out| {
            // Format: source:line: message
            const line = p.getCurrentLine();
            const msg = p.getErrorMsg();
            var buf_pos: usize = 0;

            // Copy source name
            if (source_name.len > 0 and buf_pos + source_name.len + 1 < 256) {
                @memcpy(out[buf_pos .. buf_pos + source_name.len], source_name);
                buf_pos += source_name.len;
                out[buf_pos] = ':';
                buf_pos += 1;
            }

            // Format line number
            var line_buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{line}) catch "?";
            if (buf_pos + line_str.len + 2 < 256) {
                @memcpy(out[buf_pos .. buf_pos + line_str.len], line_str);
                buf_pos += line_str.len;
                out[buf_pos] = ':';
                buf_pos += 1;
                out[buf_pos] = ' ';
                buf_pos += 1;
            }

            // Copy message
            if (msg.len > 0 and buf_pos + msg.len < 256) {
                @memcpy(out[buf_pos .. buf_pos + msg.len], msg);
                buf_pos += msg.len;
            } else if (msg.len == 0) {
                // Fallback to error name
                const name = @errorName(err);
                if (buf_pos + name.len < 256) {
                    @memcpy(out[buf_pos .. buf_pos + name.len], name);
                    buf_pos += name.len;
                }
            }
            out[buf_pos] = 0; // null terminate
        }
        return err;
    };

    return try builder.toRawProto(allocator, 0);
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
