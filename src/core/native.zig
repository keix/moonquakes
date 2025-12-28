const std = @import("std");

pub const NativeFnId = enum(u8) {
    print = 0, // Keep print as hardcoded function (existing behavior)
    io_write = 1, // New: io.write function
    // Future: os_exit, math_abs, etc.
};

pub const NativeFn = struct {
    id: NativeFnId,

    pub fn init(id: NativeFnId) NativeFn {
        return NativeFn{ .id = id };
    }
};
