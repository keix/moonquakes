//! Traceback State
//!
//! Snapshot storage for Lua-visible traceback reporting during error unwinding.

const TValue = @import("../runtime/value.zig").TValue;
const ClosureObject = @import("../runtime/gc/object.zig").ClosureObject;

pub const TracebackState = struct {
    snapshot_lines: [256]u32 = [_]u32{0} ** 256,
    snapshot_names: [256]TValue = [_]TValue{.nil} ** 256,
    snapshot_closures: [256]?*ClosureObject = [_]?*ClosureObject{null} ** 256,
    snapshot_sources: [256][]const u8 = [_][]const u8{""} ** 256,
    snapshot_def_lines: [256]u32 = [_]u32{0} ** 256,
    snapshot_count: u16 = 0,
    snapshot_has_error_frame: bool = false,
};
