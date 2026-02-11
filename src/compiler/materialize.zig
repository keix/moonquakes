const std = @import("std");
const proto = @import("proto.zig");
const RawProto = proto.RawProto;
const ConstRef = proto.ConstRef;
const Upvaldesc = proto.Upvaldesc;
const Instruction = @import("opcodes.zig").Instruction;
const TValue = @import("../runtime/value.zig").TValue;
const GC = @import("../runtime/gc/gc.zig").GC;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const ProtoObject = @import("../runtime/gc/object.zig").ProtoObject;

pub const MaterializeError = std.mem.Allocator.Error;

/// Materialize a RawProto into a runtime ProtoObject (GC-managed)
/// Converts unmaterialized constants (raw strings, native fn ids) into GC-managed TValues
///
/// GC SAFETY CONTRACT:
/// Materialization creates GC objects (strings, native closures) stored in a
/// temporary TValue array. This array is not yet attached to a ProtoObject, and
/// ProtoObject is not yet reachable from any VM root.
///
/// GC INHIBIT REQUIRED because:
/// - Objects exist but are unreachable from roots
/// - GC would collect them mid-construction
///
/// Safe when:
/// - ProtoObject is fully constructed and returned to caller
/// - Caller attaches ProtoObject to VM structures (call frame, closure)
///
/// Note: The allocator parameter is kept for API compatibility but arrays are
/// allocated using gc.allocator to ensure consistent deallocation during GC sweep.
pub fn materialize(raw: *const RawProto, gc: *GC, allocator: std.mem.Allocator) MaterializeError!*ProtoObject {
    _ = allocator; // Use gc.allocator for all allocations (GC owns these arrays)

    gc.inhibitGC();
    defer gc.allowGC();

    // Materialize constants using GC's allocator
    const k = try materializeConstants(raw, gc);

    // Recursively materialize nested protos
    const nested_protos = try materializeNestedProtos(raw.protos, gc);

    // Duplicate code and upvalues using GC's allocator (ProtoObject owns its own copies)
    const code = try gc.allocator.dupe(Instruction, raw.code);
    const upvalues = try gc.allocator.dupe(Upvaldesc, raw.upvalues);

    // Allocate via GC - ProtoObject is now GC-managed
    return gc.allocProto(
        k,
        code,
        nested_protos,
        raw.numparams,
        raw.is_vararg,
        raw.maxstacksize,
        raw.nups,
        upvalues,
    );
}

fn materializeConstants(raw: *const RawProto, gc: *GC) MaterializeError![]const TValue {
    if (raw.const_refs.len == 0) {
        return &[_]TValue{};
    }

    const k = try gc.allocator.alloc(TValue, raw.const_refs.len);

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
) MaterializeError![]const *ProtoObject {
    if (raw_protos.len == 0) {
        return &[_]*ProtoObject{};
    }

    const protos = try gc.allocator.alloc(*ProtoObject, raw_protos.len);

    for (raw_protos, 0..) |raw, i| {
        // Pass a dummy allocator since we use gc.allocator internally now
        protos[i] = try materialize(raw, gc, gc.allocator);
    }

    return protos;
}
