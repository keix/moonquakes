const std = @import("std");
const Proto = @import("../compiler/proto.zig").Proto;
const NativeFn = @import("native.zig").NativeFn;

/// Discriminates how VM calls a function: bytecode execution or native dispatch.
/// This is the "call model" - not a GC object, not a Value itself.
pub const FunctionKind = union(enum) {
    bytecode: *const Proto,
    native: NativeFn,

    pub fn isBytecode(self: FunctionKind) bool {
        return self == .bytecode;
    }

    pub fn isNative(self: FunctionKind) bool {
        return self == .native;
    }
};
