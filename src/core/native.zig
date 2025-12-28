const std = @import("std");

pub const NativeFnId = enum(u8) {
    print, // Keep first for parser compatibility
    io_write,
    tostring,
};

pub const NativeFn = struct {
    id: NativeFnId,

    pub fn init(id: NativeFnId) NativeFn {
        return NativeFn{ .id = id };
    }
};
