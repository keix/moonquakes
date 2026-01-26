const std = @import("std");
const object = @import("gc/object.zig");
const GCObject = object.GCObject;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;

/// TValue type tag
/// Note: 'object' variant added for gradual migration to unified GCObject pointer.
/// Old variants (closure, string, table) kept for compatibility.
pub const ValueType = enum(u8) {
    nil,
    boolean,
    integer,
    number,
    closure,
    string,
    table,
    object, // unified GCObject pointer
};

// TODO: Refactor to final form with 5 variants only:
//
//   pub const TValue = union(enum) {
//       nil,
//       boolean: bool,
//       integer: i64,
//       number: f64,
//       object: *GCObject,  // all GC types unified
//   };
//
// Principles:
// - TValue knows only "immediate or reference"
// - GC knows only GCObject
// - Type dispatch happens via GCObject.type field
//
// This removes closure/string/table variants and unifies all GC objects.
pub const TValue = union(ValueType) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,
    closure: *ClosureObject,
    string: *const StringObject,
    table: *TableObject,
    object: *GCObject, // unified GCObject pointer

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

    pub fn isClosure(self: TValue) bool {
        return self == .closure;
    }

    pub fn isString(self: TValue) bool {
        return self == .string;
    }

    pub fn isTable(self: TValue) bool {
        return self == .table;
    }

    pub fn isObject(self: TValue) bool {
        return self == .object;
    }

    // ===== Object accessors (for .object variant) =====

    /// Get StringObject from .object variant
    pub fn asString(self: TValue) ?*StringObject {
        if (self == .object and self.object.type == .string) {
            return object.getObject(StringObject, self.object);
        }
        return null;
    }

    /// Get TableObject from .object variant
    pub fn asTable(self: TValue) ?*TableObject {
        if (self == .object and self.object.type == .table) {
            return object.getObject(TableObject, self.object);
        }
        return null;
    }

    /// Get ClosureObject from .object variant
    pub fn asClosure(self: TValue) ?*ClosureObject {
        if (self == .object and self.object.type == .closure) {
            return object.getObject(ClosureObject, self.object);
        }
        return null;
    }

    /// Get NativeClosureObject from .object variant
    pub fn asNativeClosure(self: TValue) ?*NativeClosureObject {
        if (self == .object and self.object.type == .native_closure) {
            return object.getObject(NativeClosureObject, self.object);
        }
        return null;
    }

    /// Check if .object variant is callable (closure or native_closure)
    pub fn isCallable(self: TValue) bool {
        if (self == .object) {
            return self.object.type == .closure or self.object.type == .native_closure;
        }
        return false;
    }

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

    pub fn toClosure(self: TValue) ?*ClosureObject {
        return switch (self) {
            .closure => |c| c,
            else => null,
        };
    }

    // ===== Constructors (create TValue from GC objects via .object variant) =====

    /// Create TValue from StringObject
    pub fn fromString(str: *StringObject) TValue {
        return .{ .object = &str.header };
    }

    /// Create TValue from TableObject
    pub fn fromTable(tbl: *TableObject) TValue {
        return .{ .object = &tbl.header };
    }

    /// Create TValue from ClosureObject
    pub fn fromClosure(closure: *ClosureObject) TValue {
        return .{ .object = &closure.header };
    }

    /// Create TValue from NativeClosureObject
    pub fn fromNativeClosure(nc: *NativeClosureObject) TValue {
        return .{ .object = &nc.header };
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
            .closure => |c| try writer.print("function: 0x{x}", .{@intFromPtr(c)}),
            .string => |s| try writer.print("{s}", .{s.asSlice()}),
            .table => |t| try writer.print("table: 0x{x}", .{@intFromPtr(t)}),
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
            .closure => |ac| b == .closure and ac == b.closure,
            .string => |as| b == .string and as == b.string, // Pointer equality (interned strings)
            .table => |at| b == .table and at == b.table,
            .object => |ao| b == .object and ao == b.object, // Pointer equality
        };
    }
};
