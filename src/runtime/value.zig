const std = @import("std");
const object = @import("gc/object.zig");
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const FunctionKind = @import("function.zig").FunctionKind;

/// Note:
/// Current TValue includes primitive types and closure.
/// Later this union will be extended with more pointer types (string, table, GCObject*).
pub const ValueType = enum(u8) {
    nil,
    boolean,
    integer,
    number,
    closure,
    function,
    string,
    table,
};

pub const TValue = union(ValueType) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,
    closure: *ClosureObject,
    function: FunctionKind,
    string: *const StringObject,
    table: *TableObject,

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

    pub fn isFunction(self: TValue) bool {
        return self == .function;
    }

    pub fn isTable(self: TValue) bool {
        return self == .table;
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
            .function => |f| switch (f) {
                .bytecode => |p| try writer.print("function: 0x{x}", .{@intFromPtr(p)}),
                .native => |nf| try writer.print("native_function_{}", .{@intFromEnum(nf.id)}),
            },
            .string => |s| try writer.print("{s}", .{s.asSlice()}),
            .table => |t| try writer.print("table: 0x{x}", .{@intFromPtr(t)}),
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
            .function => |af| switch (af) {
                .bytecode => |ap| b == .function and b.function == .bytecode and ap == b.function.bytecode,
                .native => |anf| b == .function and b.function == .native and std.mem.eql(u8, @tagName(anf.id), @tagName(b.function.native.id)),
            },
            .string => |as| b == .string and as == b.string, // Pointer equality (interned strings)
            .table => |at| b == .table and at == b.table,
        };
    }
};
