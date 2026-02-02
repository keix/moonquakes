const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Instruction = @import("opcodes.zig").Instruction;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;

/// Upvalue descriptor - describes how to capture an upvalue
pub const Upvaldesc = struct {
    /// If true, upvalue is in enclosing function's stack (local variable)
    /// If false, upvalue is in enclosing function's upvalues
    instack: bool,
    /// Index: stack slot if instack, upvalue index otherwise
    idx: u8,
    /// Name of the upvalue (for debugging, optional)
    name: ?[]const u8 = null,
};

/// Runtime prototype - contains materialized TValues
/// Used by VM for execution
pub const Proto = struct {
    k: []const TValue,
    code: []const Instruction,
    protos: []const *const Proto = &.{}, // Nested function prototypes
    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
    nups: u8 = 0, // Number of upvalues
    upvalues: []const Upvaldesc = &.{}, // Upvalue descriptors
};

/// Constant reference - type tag + index into type-specific array
pub const ConstRef = struct {
    kind: ConstKind,
    index: u16,

    pub const ConstKind = enum(u8) {
        nil,
        boolean,
        integer,
        number,
        string,
        native_fn,
    };
};

/// Compile-time prototype - contains unmaterialized constants
/// Parser produces this, then materialize() converts to Proto
pub const RawProto = struct {
    code: []const Instruction,

    // Type-specific constant arrays
    booleans: []const bool,
    integers: []const i64,
    numbers: []const f64,
    strings: []const []const u8,
    native_ids: []const NativeFnId,

    // Ordered constant references
    const_refs: []const ConstRef,

    // Nested prototypes
    protos: []const *const RawProto,

    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
    nups: u8 = 0,
    upvalues: []const Upvaldesc = &.{},
};
