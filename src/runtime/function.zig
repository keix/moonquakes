const std = @import("std");
const Proto = @import("../compiler/proto.zig").Proto;
const NativeFn = @import("native.zig").NativeFn;

pub const Function = union(enum) {
    bytecode: *const Proto,
    native: NativeFn,

    pub fn isBytecode(self: Function) bool {
        return self == .bytecode;
    }

    pub fn isNative(self: Function) bool {
        return self == .native;
    }
};
