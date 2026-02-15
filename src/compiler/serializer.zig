const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ProtoObject = object.ProtoObject;
const Upvaldesc = @import("proto.zig").Upvaldesc;
const Instruction = @import("opcodes.zig").Instruction;

/// Moonquakes bytecode signature
pub const SIGNATURE = "\x1bMOO";
pub const VERSION: u8 = 1;

/// Constant type tags
const ConstTag = enum(u8) {
    nil = 0,
    boolean_false = 1,
    boolean_true = 2,
    integer = 3,
    number = 4,
    string = 5,
};

/// Dump a ProtoObject to binary bytecode
pub fn dumpProto(proto: *const ProtoObject, allocator: std.mem.Allocator, strip: bool) ![]u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer result.deinit(allocator);

    // Write header
    try result.appendSlice(allocator, SIGNATURE);
    try result.append(allocator, VERSION);
    try result.append(allocator, 4); // instruction size
    try result.append(allocator, 8); // integer size
    try result.append(allocator, 8); // number size

    // Write proto recursively
    try writeProto(&result, allocator, proto, strip);

    return result.toOwnedSlice(allocator);
}

fn writeProto(result: *std.ArrayList(u8), allocator: std.mem.Allocator, proto: *const ProtoObject, strip: bool) !void {
    // Write function header
    try result.append(allocator, proto.numparams);
    try result.append(allocator, if (proto.is_vararg) @as(u8, 1) else @as(u8, 0));
    try result.append(allocator, proto.maxstacksize);
    try result.append(allocator, proto.nups);

    // Write code
    try writeU32(result, allocator, @intCast(proto.code.len));
    for (proto.code) |instr| {
        try writeU32(result, allocator, @bitCast(instr));
    }

    // Write constants
    try writeU32(result, allocator, @intCast(proto.k.len));
    for (proto.k) |k| {
        try writeConstant(result, allocator, k);
    }

    // Write upvalue descriptors
    try writeU32(result, allocator, @intCast(proto.upvalues.len));
    for (proto.upvalues) |upv| {
        try result.append(allocator, if (upv.instack) @as(u8, 1) else @as(u8, 0));
        try result.append(allocator, upv.idx);
    }

    // Write nested protos
    try writeU32(result, allocator, @intCast(proto.protos.len));
    for (proto.protos) |nested| {
        try writeProto(result, allocator, nested, strip);
    }

    // Write debug info (unless stripped)
    if (strip) {
        try writeU32(result, allocator, 0); // source_len
        try writeU32(result, allocator, 0); // lineinfo_count
    } else {
        // Source name
        try writeU32(result, allocator, @intCast(proto.source.len));
        try result.appendSlice(allocator, proto.source);

        // Line info
        try writeU32(result, allocator, @intCast(proto.lineinfo.len));
        for (proto.lineinfo) |line| {
            try writeU32(result, allocator, line);
        }
    }
}

fn writeConstant(result: *std.ArrayList(u8), allocator: std.mem.Allocator, k: TValue) !void {
    switch (k) {
        .nil => try result.append(allocator, @intFromEnum(ConstTag.nil)),
        .boolean => |b| {
            if (b) {
                try result.append(allocator, @intFromEnum(ConstTag.boolean_true));
            } else {
                try result.append(allocator, @intFromEnum(ConstTag.boolean_false));
            }
        },
        .integer => |i| {
            try result.append(allocator, @intFromEnum(ConstTag.integer));
            try writeI64(result, allocator, i);
        },
        .number => |n| {
            try result.append(allocator, @intFromEnum(ConstTag.number));
            try writeF64(result, allocator, n);
        },
        .object => |obj| {
            if (obj.type == .string) {
                const str: *object.StringObject = @fieldParentPtr("header", obj);
                try result.append(allocator, @intFromEnum(ConstTag.string));
                const slice = str.asSlice();
                try writeU32(result, allocator, @intCast(slice.len));
                try result.appendSlice(allocator, slice);
            } else {
                // Other object types not supported in constants
                return error.UnsupportedConstantType;
            }
        },
    }
}

fn writeU32(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    const bytes: [4]u8 = @bitCast(value);
    try result.appendSlice(allocator, &bytes);
}

fn writeI64(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    const bytes: [8]u8 = @bitCast(value);
    try result.appendSlice(allocator, &bytes);
}

fn writeF64(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64) !void {
    const bytes: [8]u8 = @bitCast(value);
    try result.appendSlice(allocator, &bytes);
}

/// Load a ProtoObject from binary bytecode
pub fn loadProto(data: []const u8, gc: anytype, allocator: std.mem.Allocator) !*ProtoObject {
    var reader = ByteReader{ .data = data, .pos = 0 };

    // Verify header
    const sig = reader.readBytes(4) orelse return error.InvalidBytecode;
    if (!std.mem.eql(u8, sig, SIGNATURE)) return error.InvalidSignature;

    const version = reader.readU8() orelse return error.InvalidBytecode;
    if (version != VERSION) return error.UnsupportedVersion;

    _ = reader.readU8() orelse return error.InvalidBytecode; // instruction size
    _ = reader.readU8() orelse return error.InvalidBytecode; // integer size
    _ = reader.readU8() orelse return error.InvalidBytecode; // number size

    // Read proto
    return readProto(&reader, gc, allocator);
}

fn readProto(reader: *ByteReader, gc: anytype, allocator: std.mem.Allocator) !*ProtoObject {
    // Read function header
    const numparams = reader.readU8() orelse return error.InvalidBytecode;
    const is_vararg = (reader.readU8() orelse return error.InvalidBytecode) != 0;
    const maxstacksize = reader.readU8() orelse return error.InvalidBytecode;
    const nups = reader.readU8() orelse return error.InvalidBytecode;

    // Read code
    const code_count = reader.readU32() orelse return error.InvalidBytecode;
    const code = try allocator.alloc(Instruction, code_count);
    errdefer allocator.free(code);
    for (code) |*instr| {
        const raw = reader.readU32() orelse return error.InvalidBytecode;
        instr.* = @bitCast(raw);
    }

    // Read constants
    const k_count = reader.readU32() orelse return error.InvalidBytecode;
    const k = try allocator.alloc(TValue, k_count);
    errdefer allocator.free(k);
    for (k) |*kval| {
        kval.* = try readConstant(reader, gc);
    }

    // Read upvalue descriptors
    const upv_count = reader.readU32() orelse return error.InvalidBytecode;
    const upvalues = try allocator.alloc(Upvaldesc, upv_count);
    errdefer allocator.free(upvalues);
    for (upvalues) |*upv| {
        upv.instack = (reader.readU8() orelse return error.InvalidBytecode) != 0;
        upv.idx = reader.readU8() orelse return error.InvalidBytecode;
        upv.name = null;
    }

    // Read nested protos
    const proto_count = reader.readU32() orelse return error.InvalidBytecode;
    const protos = try allocator.alloc(*ProtoObject, proto_count);
    errdefer allocator.free(protos);
    for (protos) |*p| {
        p.* = try readProto(reader, gc, allocator);
    }

    // Read debug info
    const source_len = reader.readU32() orelse return error.InvalidBytecode;
    const source = if (source_len > 0) blk: {
        const src = reader.readBytes(source_len) orelse return error.InvalidBytecode;
        const s = try allocator.alloc(u8, source_len);
        @memcpy(s, src);
        break :blk s;
    } else "";

    const lineinfo_count = reader.readU32() orelse return error.InvalidBytecode;
    const lineinfo = if (lineinfo_count > 0) blk: {
        const lines = try allocator.alloc(u32, lineinfo_count);
        for (lines) |*line| {
            line.* = reader.readU32() orelse return error.InvalidBytecode;
        }
        break :blk lines;
    } else &[_]u32{};

    // Allocate ProtoObject through GC
    return gc.allocProto(k, code, protos, numparams, is_vararg, maxstacksize, nups, upvalues, source, lineinfo);
}

fn readConstant(reader: *ByteReader, gc: anytype) !TValue {
    const tag_byte = reader.readU8() orelse return error.InvalidBytecode;
    const tag: ConstTag = @enumFromInt(tag_byte);

    return switch (tag) {
        .nil => .nil,
        .boolean_false => TValue{ .boolean = false },
        .boolean_true => TValue{ .boolean = true },
        .integer => blk: {
            const val = reader.readI64() orelse return error.InvalidBytecode;
            break :blk TValue{ .integer = val };
        },
        .number => blk: {
            const val = reader.readF64() orelse return error.InvalidBytecode;
            break :blk TValue{ .number = val };
        },
        .string => blk: {
            const len = reader.readU32() orelse return error.InvalidBytecode;
            const bytes = reader.readBytes(len) orelse return error.InvalidBytecode;
            const str = try gc.allocString(bytes);
            break :blk TValue.fromString(str);
        },
    };
}

const ByteReader = struct {
    data: []const u8,
    pos: usize,

    fn readU8(self: *ByteReader) ?u8 {
        if (self.pos >= self.data.len) return null;
        const val = self.data[self.pos];
        self.pos += 1;
        return val;
    }

    fn readU32(self: *ByteReader) ?u32 {
        if (self.pos + 4 > self.data.len) return null;
        const bytes: *const [4]u8 = @ptrCast(self.data[self.pos..][0..4]);
        self.pos += 4;
        return @bitCast(bytes.*);
    }

    fn readI64(self: *ByteReader) ?i64 {
        if (self.pos + 8 > self.data.len) return null;
        const bytes: *const [8]u8 = @ptrCast(self.data[self.pos..][0..8]);
        self.pos += 8;
        return @bitCast(bytes.*);
    }

    fn readF64(self: *ByteReader) ?f64 {
        if (self.pos + 8 > self.data.len) return null;
        const bytes: *const [8]u8 = @ptrCast(self.data[self.pos..][0..8]);
        self.pos += 8;
        return @bitCast(bytes.*);
    }

    fn readBytes(self: *ByteReader, len: u32) ?[]const u8 {
        if (self.pos + len > self.data.len) return null;
        const slice = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }
};

/// Check if data starts with bytecode signature
pub fn isBytecode(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], SIGNATURE);
}
