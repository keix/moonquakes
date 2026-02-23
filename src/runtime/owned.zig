//! Owned Result Types
//!
//! Values that escape VM/GC lifetime. Strings are copied and owned by caller.
//! Used when returning execution results to external code.

const std = @import("std");
const TValue = @import("value.zig").TValue;
const ReturnValue = @import("../vm/execution.zig").ReturnValue;

/// Owned value that doesn't depend on VM/GC lifetime.
/// Strings are copied and owned by the caller.
pub const OwnedValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []u8,

    pub fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn format(self: OwnedValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .boolean => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{}", .{i}),
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("{s}", .{s}),
        }
    }
};

/// Return value from Moonquakes execution.
/// Owns all GC-managed data (strings copied out).
pub const OwnedReturnValue = union(enum) {
    none,
    single: OwnedValue,

    pub fn deinit(self: *OwnedReturnValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single => |*v| v.deinit(allocator),
            .none => {},
        }
    }
};

/// Convert TValue to OwnedValue (copies strings)
pub fn toOwnedValue(allocator: std.mem.Allocator, val: TValue) !OwnedValue {
    return switch (val) {
        .nil => .nil,
        .boolean => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .number => |n| .{ .number = n },
        .object => |obj| switch (obj.type) {
            .string => .{ .string = try allocator.dupe(u8, val.asString().?.asSlice()) },
            .table => .nil, // TODO: serialize table
            .closure, .native_closure => .nil, // TODO: represent closure
            .upvalue, .userdata, .proto, .thread => .nil,
        },
    };
}

/// Convert VM ReturnValue to OwnedReturnValue (copies GC-managed data)
pub fn toOwnedReturnValue(allocator: std.mem.Allocator, result: ReturnValue) !OwnedReturnValue {
    return switch (result) {
        .none => .none,
        .single => |val| .{ .single = try toOwnedValue(allocator, val) },
        .multiple => |vals| {
            // Return first value for now (multi-value assignment handled separately)
            if (vals.len > 0) {
                return .{ .single = try toOwnedValue(allocator, vals[0]) };
            }
            return .none;
        },
    };
}
