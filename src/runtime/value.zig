//! TValue - Tagged Value Representation
//!
//! Lua values are dynamically typed. TValue is the universal container.
//!
//! Design:
//!   - Tagged union (Zig native, no manual bit packing)
//!   - Immediate types: nil, boolean, integer (i64), number (f64)
//!   - Reference type: object (*GCObject for all heap types)
//!
//! Why not NaN-boxing?
//!   - Zig's tagged union is type-safe and clear
//!   - No pointer arithmetic or bit manipulation
//!   - Easy to debug and maintain
//!
//! GC interaction:
//!   - Only .object variant holds GC references
//!   - Marking a TValue marks the underlying GCObject if present

const std = @import("std");
const object = @import("gc/object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;

/// TValue: Lua value representation
/// - Immediate values: nil, boolean, integer, number
/// - Reference values: object (all GC-managed types)
pub const TValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    object: *GCObject,

    pub fn isNil(self: TValue) bool {
        return self == .nil;
    }

    pub fn isBoolean(self: TValue) bool {
        return self == .boolean;
    }

    pub fn isInteger(self: TValue) bool {
        return self == .integer;
    }

    pub fn isNumber(self: TValue) bool {
        return self == .number;
    }

    pub fn isObject(self: TValue) bool {
        return self == .object;
    }

    pub fn isString(self: TValue) bool {
        return self == .object and self.object.type == .string;
    }

    pub fn isTable(self: TValue) bool {
        return self == .object and self.object.type == .table;
    }

    pub fn isClosure(self: TValue) bool {
        return self == .object and self.object.type == .closure;
    }

    pub fn isNativeClosure(self: TValue) bool {
        return self == .object and self.object.type == .native_closure;
    }

    pub fn isCallable(self: TValue) bool {
        return self == .object and (self.object.type == .closure or self.object.type == .native_closure);
    }

    pub fn isUserdata(self: TValue) bool {
        return self == .object and self.object.type == .userdata;
    }

    pub fn isThread(self: TValue) bool {
        return self == .object and self.object.type == .thread;
    }

    pub fn asString(self: TValue) ?*StringObject {
        if (self == .object and self.object.type == .string) {
            return object.getObject(StringObject, self.object);
        }
        return null;
    }

    pub fn asTable(self: TValue) ?*TableObject {
        if (self == .object and self.object.type == .table) {
            return object.getObject(TableObject, self.object);
        }
        return null;
    }

    pub fn asClosure(self: TValue) ?*ClosureObject {
        if (self == .object and self.object.type == .closure) {
            return object.getObject(ClosureObject, self.object);
        }
        return null;
    }

    pub fn asNativeClosure(self: TValue) ?*NativeClosureObject {
        if (self == .object and self.object.type == .native_closure) {
            return object.getObject(NativeClosureObject, self.object);
        }
        return null;
    }

    pub fn asUserdata(self: TValue) ?*UserdataObject {
        if (self == .object and self.object.type == .userdata) {
            return object.getObject(UserdataObject, self.object);
        }
        return null;
    }

    pub fn asThread(self: TValue) ?*ThreadObject {
        if (self == .object and self.object.type == .thread) {
            return object.getObject(ThreadObject, self.object);
        }
        return null;
    }

    /// Convert float to integer safely, checking for finite, integral, and in-range
    fn floatToIntSafe(n: f64) ?i64 {
        // Must be finite (not inf/nan)
        if (!std.math.isFinite(n)) return null;
        // Must be integral (no fractional part)
        if (std.math.modf(n).fpart != 0.0) return null;
        // Must be in i64 range
        const min_i64: f64 = @floatFromInt(std.math.minInt(i64));
        const max_i64: f64 = @floatFromInt(std.math.maxInt(i64));
        if (n < min_i64 or n > max_i64) return null;
        return @intFromFloat(n);
    }

    pub fn toInteger(self: TValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .number => |n| floatToIntSafe(n),
            .object => |obj| {
                // Lua 5.4: strings are coerced to numbers in arithmetic
                if (obj.type == .string) {
                    const str = object.getObject(StringObject, obj);
                    const slice = std.mem.trim(u8, str.asSlice(), " \t\n\r");
                    const n = std.fmt.parseFloat(f64, slice) catch return null;
                    return floatToIntSafe(n);
                }
                return null;
            },
            else => null,
        };
    }

    pub fn toNumber(self: TValue) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .number => |n| n,
            .object => |obj| {
                // Lua 5.4: strings are coerced to numbers in arithmetic
                if (obj.type == .string) {
                    const str = object.getObject(StringObject, obj);
                    const slice = std.mem.trim(u8, str.asSlice(), " \t\n\r");
                    return std.fmt.parseFloat(f64, slice) catch null;
                }
                return null;
            },
            else => null,
        };
    }

    pub fn toBoolean(self: TValue) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn fromString(str: *StringObject) TValue {
        return .{ .object = &str.header };
    }

    pub fn fromTable(tbl: *TableObject) TValue {
        return .{ .object = &tbl.header };
    }

    pub fn fromClosure(closure: *ClosureObject) TValue {
        return .{ .object = &closure.header };
    }

    pub fn fromNativeClosure(nc: *NativeClosureObject) TValue {
        return .{ .object = &nc.header };
    }

    pub fn fromUserdata(ud: *UserdataObject) TValue {
        return .{ .object = &ud.header };
    }

    pub fn fromThread(thread: *ThreadObject) TValue {
        return .{ .object = &thread.header };
    }

    pub fn format(
        self: TValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .nil => try writer.print("nil", .{}),
            .boolean => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{}", .{i}),
            .number => |n| try writer.print("{d}", .{n}),
            .object => |obj| switch (obj.type) {
                .string => {
                    const s = object.getObject(StringObject, obj);
                    try writer.print("{s}", .{s.asSlice()});
                },
                .table => try writer.print("table: 0x{x}", .{@intFromPtr(obj)}),
                .closure => try writer.print("function: 0x{x}", .{@intFromPtr(obj)}),
                .native_closure => try writer.print("function: 0x{x}", .{@intFromPtr(obj)}),
                .upvalue => try writer.print("upvalue: 0x{x}", .{@intFromPtr(obj)}),
                .userdata => try writer.print("userdata: 0x{x}", .{@intFromPtr(obj)}),
                .proto => try writer.print("proto: 0x{x}", .{@intFromPtr(obj)}),
                .thread => try writer.print("thread: 0x{x}", .{@intFromPtr(obj)}),
            },
        }
    }

    pub fn eql(a: TValue, b: TValue) bool {
        const floatToIntExact = struct {
            fn convert(n: f64) ?i64 {
                if (!std.math.isFinite(n)) return null;
                if (n != @floor(n)) return null;
                const max_i = std.math.maxInt(i64);
                const min_i = std.math.minInt(i64);
                const max_f: f64 = @floatFromInt(max_i);
                const min_f: f64 = @floatFromInt(min_i);
                if (n < min_f or n > max_f) return null;
                if (!intFitsFloat(max_i) and n >= max_f) return null;
                const i: i64 = @intFromFloat(n);
                if (@as(f64, @floatFromInt(i)) != n) return null;
                return i;
            }

            fn intFitsFloat(i: i64) bool {
                const max_exact: i64 = @as(i64, 1) << 53;
                return i >= -max_exact and i <= max_exact;
            }
        }.convert;
        return switch (a) {
            .nil => b == .nil,
            .boolean => |ab| b == .boolean and ab == b.boolean,
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                .number => |bn| blk: {
                    if (floatToIntExact(bn)) |bi| break :blk ai == bi;
                    break :blk @as(f64, @floatFromInt(ai)) == bn;
                },
                else => false,
            },
            .number => |an| switch (b) {
                .integer => |bi| blk: {
                    if (floatToIntExact(an)) |ai| break :blk ai == bi;
                    break :blk an == @as(f64, @floatFromInt(bi));
                },
                .number => |bn| an == bn,
                else => false,
            },
            .object => |ao| b == .object and ao == b.object,
        };
    }
};
