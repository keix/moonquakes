const std = @import("std");
const object = @import("gc/object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;

/// TValue: Lua value representation
/// - Immediate values: nil, boolean, integer, number
/// - Reference values: object (all GC-managed types)
pub const TValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    object: *GCObject,

    // ===== Type predicates =====

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

    // ===== Object accessors =====

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

    // ===== Numeric conversions =====

    pub fn toInteger(self: TValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .number => |n| if (std.math.modf(n).fpart == 0.0) @intFromFloat(n) else null,
            else => null,
        };
    }

    pub fn toNumber(self: TValue) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .number => |n| n,
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

    // ===== Constructors =====

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

    // ===== Formatting =====

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
            },
        }
    }

    // ===== Equality =====

    pub fn eql(a: TValue, b: TValue) bool {
        return switch (a) {
            .nil => b == .nil,
            .boolean => |ab| b == .boolean and ab == b.boolean,
            .integer => |ai| switch (b) {
                .integer => |bi| ai == bi,
                .number => |bn| @as(f64, @floatFromInt(ai)) == bn,
                else => false,
            },
            .number => |an| switch (b) {
                .integer => |bi| an == @as(f64, @floatFromInt(bi)),
                .number => |bn| an == bn,
                else => false,
            },
            .object => |ao| b == .object and ao == b.object,
        };
    }
};
