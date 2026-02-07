const std = @import("std");
const proto = @import("proto.zig");
const RawProto = proto.RawProto;
const Proto = proto.Proto;
const ConstRef = proto.ConstRef;
const Upvaldesc = proto.Upvaldesc;
const Instruction = @import("opcodes.zig").Instruction;
const TValue = @import("../runtime/value.zig").TValue;
const GC = @import("../runtime/gc/gc.zig").GC;
const NativeFn = @import("../runtime/native.zig").NativeFn;

pub const MaterializeError = std.mem.Allocator.Error;

/// Materialize a RawProto into a runtime Proto
/// Converts unmaterialized constants (raw strings, native fn ids) into GC-managed TValues
///
/// GC SAFETY CONTRACT:
/// Materialization creates GC objects (strings, native closures) stored in a
/// temporary TValue array. This array is not yet attached to a Proto, and
/// Proto is not yet reachable from any VM root.
///
/// GC INHIBIT REQUIRED because:
/// - Objects exist but are unreachable from roots
/// - GC would collect them mid-construction
///
/// Safe when:
/// - Proto is fully constructed and returned to caller
/// - Caller attaches Proto to VM structures (call frame, closure)
pub fn materialize(raw: *const RawProto, gc: *GC, allocator: std.mem.Allocator) MaterializeError!*Proto {
    gc.inhibitGC();
    defer gc.allowGC();

    // Materialize constants
    const k = try materializeConstants(raw, gc, allocator);

    // Recursively materialize nested protos
    const nested_protos = try materializeNestedProtos(raw.protos, gc, allocator);

    // Duplicate code and upvalues (Proto owns its own copies)
    const code = try allocator.dupe(Instruction, raw.code);
    const upvalues = try allocator.dupe(Upvaldesc, raw.upvalues);

    // Allocate and return Proto
    const result = try allocator.create(Proto);
    result.* = Proto{
        .k = k,
        .code = code,
        .protos = nested_protos,
        .numparams = raw.numparams,
        .is_vararg = raw.is_vararg,
        .maxstacksize = raw.maxstacksize,
        .nups = raw.nups,
        .upvalues = upvalues,
    };

    return result;
}

fn materializeConstants(raw: *const RawProto, gc: *GC, allocator: std.mem.Allocator) MaterializeError![]const TValue {
    if (raw.const_refs.len == 0) {
        return &[_]TValue{};
    }

    const k = try allocator.alloc(TValue, raw.const_refs.len);

    for (raw.const_refs, 0..) |ref, i| {
        k[i] = switch (ref.kind) {
            .nil => TValue.nil,
            .boolean => .{ .boolean = raw.booleans[ref.index] },
            .integer => .{ .integer = raw.integers[ref.index] },
            .number => .{ .number = raw.numbers[ref.index] },
            // GC.allocString handles string interning - duplicates in RawProto will share ObjString
            .string => TValue.fromString(gc.allocString(raw.strings[ref.index]) catch return error.OutOfMemory),
            .native_fn => TValue.fromNativeClosure(
                gc.allocNativeClosure(NativeFn.init(raw.native_ids[ref.index])) catch return error.OutOfMemory,
            ),
        };
    }

    return k;
}

fn materializeNestedProtos(
    raw_protos: []const *const RawProto,
    gc: *GC,
    allocator: std.mem.Allocator,
) MaterializeError![]const *const Proto {
    if (raw_protos.len == 0) {
        return &[_]*const Proto{};
    }

    const protos = try allocator.alloc(*const Proto, raw_protos.len);

    for (raw_protos, 0..) |raw, i| {
        protos[i] = try materialize(raw, gc, allocator);
    }

    return protos;
}
