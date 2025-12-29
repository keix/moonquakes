const std = @import("std");
const Proto = @import("../compiler/proto.zig").Proto;

/// Closure represents a function instance.
/// For now, it only contains a Proto reference (no upvalues support yet).
pub const Closure = struct {
    proto: *const Proto,
    // TODO: Add upvalues support later
    // upvalues: []UpValue,

    pub fn init(proto: *const Proto) Closure {
        return .{ .proto = proto };
    }
};
