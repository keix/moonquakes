//! TValue - Tagged Value Representation
//!
//! Lua values are dynamically typed. TValue is the universal container.
//!
//! Design:
//!   - Manual payload + tag layout (PUC parity: 8-byte value, 1-byte tag)
//!   - Immediate types: nil, boolean, integer (i64), number (f64)
//!   - Reference type: object (*GCObject for all heap types)
//!
//! Why not a Zig tagged union?
//!   - union(enum) copies compile to one 16-byte SSE load/store, which
//!     cannot store-forward from the split 8-byte-payload/1-byte-tag
//!     stores the in-place setters emit — a ~13-cycle stall every time
//!     MOVE or argument staging reads a freshly written slot. With the
//!     manual layout, TValue.copy moves payload and tag at the same
//!     widths the setters write, so every load forwards.
//!   - Everything outside this file goes through kind()/is*/as*/from*
//!     accessors (representation-independence migration), so the layout
//!     is this file's private concern.
//!
//! Why not NaN-boxing?
//!   - Lua 5.4 integers are full i64 and do not fit a NaN payload;
//!     PUC's TValue is also 16 bytes, so there is no size gap to close.
//!
//! GC interaction:
//!   - Only .object holds GC references
//!   - Marking a TValue marks the underlying GCObject if present

const std = @import("std");
const object = @import("gc/object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const CClosureObject = object.CClosureObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;
const FileObject = object.FileObject;

/// TValue: Lua value representation
/// - Immediate values: nil, boolean, integer, number
/// - Reference values: object (all GC-managed types)
pub const TValue = extern struct {
    value: Value,
    tt: Kind,

    pub const Value = extern union {
        boolean: bool,
        integer: i64,
        number: f64,
        object: *GCObject,
    };

    /// Value kind. Also the physical tag; code outside this file never
    /// depends on that coincidence.
    pub const Kind = enum(u8) { nil, boolean, integer, number, object };

    comptime {
        std.debug.assert(@sizeOf(TValue) == 16);
        std.debug.assert(@offsetOf(TValue, "value") == 0);
        std.debug.assert(@offsetOf(TValue, "tt") == 8);
    }

    /// Decl literal: `stack[i] = .nil;`
    pub const nil: TValue = .{ .value = .{ .integer = 0 }, .tt = .nil };

    pub inline fn kind(self: *const TValue) Kind {
        return self.tt;
    }

    // Factories. Use these (or the `.nil` decl literal) instead of
    // constructing fields outside this file.
    pub inline fn fromInt(i: i64) TValue {
        return .{ .value = .{ .integer = i }, .tt = .integer };
    }

    pub inline fn fromFloat(n: f64) TValue {
        return .{ .value = .{ .number = n }, .tt = .number };
    }

    pub inline fn fromBool(b: bool) TValue {
        return .{ .value = .{ .boolean = b }, .tt = .boolean };
    }

    pub inline fn fromObject(obj: *GCObject) TValue {
        return .{ .value = .{ .object = obj }, .tt = .object };
    }

    // In-place stores: write payload and tag directly at their natural
    // widths (8B + 1B), the same widths copy() reads back.
    pub inline fn setInt(slot: *TValue, i: i64) void {
        slot.value = .{ .integer = i };
        slot.tt = .integer;
    }

    pub inline fn setFloat(slot: *TValue, n: f64) void {
        slot.value = .{ .number = n };
        slot.tt = .number;
    }

    pub inline fn setBool(slot: *TValue, b: bool) void {
        slot.value = .{ .boolean = b };
        slot.tt = .boolean;
    }

    /// Raw identity: same kind and same payload bits by kind (integer 1
    /// and float 1.0 differ; NaN differs from NaN, as f64 == does).
    /// What std.meta.eql did for the old tagged-union representation.
    pub fn rawIdentical(a: TValue, b: TValue) bool {
        if (a.tt != b.tt) return false;
        return switch (a.tt) {
            .nil => true,
            .boolean => a.value.boolean == b.value.boolean,
            .integer => a.value.integer == b.value.integer,
            .number => a.value.number == b.value.number,
            .object => a.value.object == b.value.object,
        };
    }

    /// Slot-to-slot copy at setter granularity: an 8-byte payload move
    /// plus a 1-byte tag move. A whole-struct assignment compiles to one
    /// 16-byte SSE pair, whose load cannot store-forward from the split
    /// stores the setters emit; the mismatched widths here also keep the
    /// SLP vectorizer from re-merging the pair. Use this for hot copies
    /// whose source may be freshly written (stack/upvalue traffic);
    /// plain assignment stays fine for cold ones.
    pub inline fn copy(dst: *TValue, src: *const TValue) void {
        dst.value = src.value;
        dst.tt = src.tt;
    }

    // Unchecked payload accessors: caller must have established the kind,
    // exactly like the direct field accesses they replace.
    pub inline fn asInt(self: *const TValue) i64 {
        return self.value.integer;
    }

    pub inline fn asFloat(self: *const TValue) f64 {
        return self.value.number;
    }

    pub inline fn asBool(self: *const TValue) bool {
        return self.value.boolean;
    }

    pub inline fn asObjectPtr(self: *const TValue) *GCObject {
        return self.value.object;
    }

    pub fn isNil(self: TValue) bool {
        return self.tt == .nil;
    }

    pub fn isBoolean(self: TValue) bool {
        return self.tt == .boolean;
    }

    pub fn isInteger(self: TValue) bool {
        return self.tt == .integer;
    }

    pub fn isNumber(self: TValue) bool {
        return self.tt == .number;
    }

    pub fn isObject(self: TValue) bool {
        return self.tt == .object;
    }

    pub fn isString(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .string;
    }

    pub fn isTable(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .table;
    }

    pub fn isClosure(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .closure;
    }

    pub fn isNativeClosure(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .native_closure;
    }

    pub fn isCClosure(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .c_closure;
    }

    pub fn isCallable(self: TValue) bool {
        return self.tt == .object and
            (self.value.object.type == .closure or self.value.object.type == .native_closure or self.value.object.type == .c_closure);
    }

    pub fn isUserdata(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .userdata;
    }

    pub fn isThread(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .thread;
    }

    pub fn isFile(self: TValue) bool {
        return self.tt == .object and self.value.object.type == .file;
    }

    pub fn asString(self: TValue) ?*StringObject {
        if (self.tt == .object and self.value.object.type == .string) {
            return object.getObject(StringObject, self.value.object);
        }
        return null;
    }

    pub fn asTable(self: TValue) ?*TableObject {
        if (self.tt == .object and self.value.object.type == .table) {
            return object.getObject(TableObject, self.value.object);
        }
        return null;
    }

    pub fn asClosure(self: TValue) ?*ClosureObject {
        if (self.tt == .object and self.value.object.type == .closure) {
            return object.getObject(ClosureObject, self.value.object);
        }
        return null;
    }

    pub fn asNativeClosure(self: TValue) ?*NativeClosureObject {
        if (self.tt == .object and self.value.object.type == .native_closure) {
            return object.getObject(NativeClosureObject, self.value.object);
        }
        return null;
    }

    pub fn asCClosure(self: TValue) ?*CClosureObject {
        if (self.tt == .object and self.value.object.type == .c_closure) {
            return object.getObject(CClosureObject, self.value.object);
        }
        return null;
    }

    pub fn asUserdata(self: TValue) ?*UserdataObject {
        if (self.tt == .object and self.value.object.type == .userdata) {
            return object.getObject(UserdataObject, self.value.object);
        }
        return null;
    }

    pub fn asThread(self: TValue) ?*ThreadObject {
        if (self.tt == .object and self.value.object.type == .thread) {
            return object.getObject(ThreadObject, self.value.object);
        }
        return null;
    }

    pub fn asFile(self: TValue) ?*FileObject {
        if (self.tt == .object and self.value.object.type == .file) {
            return object.getObject(FileObject, self.value.object);
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
        return switch (self.tt) {
            .integer => self.value.integer,
            .number => floatToIntSafe(self.value.number),
            .object => {
                // Lua 5.4: strings are coerced to numbers in arithmetic
                if (self.value.object.type == .string) {
                    const str = object.getObject(StringObject, self.value.object);
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
        return switch (self.tt) {
            .integer => @floatFromInt(self.value.integer),
            .number => self.value.number,
            .object => {
                // Lua 5.4: strings are coerced to numbers in arithmetic
                if (self.value.object.type == .string) {
                    const str = object.getObject(StringObject, self.value.object);
                    const slice = std.mem.trim(u8, str.asSlice(), " \t\n\r");
                    return std.fmt.parseFloat(f64, slice) catch null;
                }
                return null;
            },
            else => null,
        };
    }

    pub fn toBoolean(self: TValue) bool {
        return switch (self.tt) {
            .nil => false,
            .boolean => self.value.boolean,
            else => true,
        };
    }

    pub fn fromString(str: *StringObject) TValue {
        return fromObject(&str.header);
    }

    pub fn fromTable(tbl: *TableObject) TValue {
        return fromObject(&tbl.header);
    }

    pub fn fromClosure(closure: *ClosureObject) TValue {
        return fromObject(&closure.header);
    }

    pub fn fromNativeClosure(nc: *NativeClosureObject) TValue {
        return fromObject(&nc.header);
    }

    pub fn fromCClosure(cc: *CClosureObject) TValue {
        return fromObject(&cc.header);
    }

    pub fn fromUserdata(ud: *UserdataObject) TValue {
        return fromObject(&ud.header);
    }

    pub fn fromThread(thread: *ThreadObject) TValue {
        return fromObject(&thread.header);
    }

    pub fn fromFile(file: *FileObject) TValue {
        return fromObject(&file.header);
    }

    pub fn format(
        self: TValue,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self.tt) {
            .nil => try writer.print("nil", .{}),
            .boolean => try writer.print("{}", .{self.value.boolean}),
            .integer => try writer.print("{}", .{self.value.integer}),
            .number => try writer.print("{d}", .{self.value.number}),
            .object => {
                const obj = self.value.object;
                switch (obj.type) {
                    .string => {
                        const s = object.getObject(StringObject, obj);
                        try writer.print("{s}", .{s.asSlice()});
                    },
                    .table => try writer.print("table: 0x{x}", .{@intFromPtr(obj)}),
                    .closure, .native_closure, .c_closure => try writer.print("function: 0x{x}", .{@intFromPtr(obj)}),
                    .dynamic_library => try writer.print("userdata: 0x{x}", .{@intFromPtr(obj)}),
                    .upvalue => try writer.print("upvalue: 0x{x}", .{@intFromPtr(obj)}),
                    .userdata => try writer.print("userdata: 0x{x}", .{@intFromPtr(obj)}),
                    .proto => try writer.print("proto: 0x{x}", .{@intFromPtr(obj)}),
                    .thread => try writer.print("thread: 0x{x}", .{@intFromPtr(obj)}),
                    .file => try writer.print("file (0x{x})", .{@intFromPtr(obj)}),
                }
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
        return switch (a.tt) {
            .nil => b.tt == .nil,
            .boolean => b.tt == .boolean and a.value.boolean == b.value.boolean,
            .integer => switch (b.tt) {
                .integer => a.value.integer == b.value.integer,
                .number => blk: {
                    if (floatToIntExact(b.value.number)) |bi| break :blk a.value.integer == bi;
                    break :blk false;
                },
                else => false,
            },
            .number => switch (b.tt) {
                .integer => blk: {
                    if (floatToIntExact(a.value.number)) |ai| break :blk ai == b.value.integer;
                    break :blk false;
                },
                .number => a.value.number == b.value.number,
                else => false,
            },
            .object => switch (b.tt) {
                .object => {
                    const ao = a.value.object;
                    const bo = b.value.object;
                    if (ao == bo) return true;
                    if (ao.type == .string and bo.type == .string) {
                        const as = object.getObject(StringObject, ao);
                        const bs = object.getObject(StringObject, bo);
                        if (as.hash != bs.hash or as.len != bs.len) return false;
                        return std.mem.eql(u8, as.asSlice(), bs.asSlice());
                    }
                    return false;
                },
                else => false,
            },
        };
    }
};
