const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ProtoObject = object.ProtoObject;
const Upvaldesc = @import("proto.zig").Upvaldesc;
const Instruction = @import("opcodes.zig").Instruction;

/// Lua 5.4 bytecode header constants (for compatibility checks in tests)
pub const SIGNATURE = "\x1bLua";
pub const VERSION: u8 = 0x54;
pub const FORMAT: u8 = 0;
pub const LUAC_DATA = "\x19\x93\r\n\x1a\n";
pub const LUAC_INT: i64 = 0x5678;
pub const LUAC_NUM: f64 = 370.5;

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
    try result.append(allocator, FORMAT);
    try result.appendSlice(allocator, LUAC_DATA);
    try result.append(allocator, @sizeOf(Instruction)); // instruction size
    try result.append(allocator, @sizeOf(i64)); // integer size
    try result.append(allocator, @sizeOf(f64)); // number size
    try writeI64(&result, allocator, LUAC_INT);
    try writeF64(&result, allocator, LUAC_NUM);

    // Write proto recursively
    try writeProto(&result, allocator, proto, strip, null);

    return result.toOwnedSlice(allocator);
}

fn writeProto(
    result: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    proto: *const ProtoObject,
    strip: bool,
    parent_source: ?[]const u8,
) !void {
    // Write function header
    try result.append(allocator, proto.numparams);
    try result.append(allocator, if (proto.is_vararg) @as(u8, 1) else @as(u8, 0));
    try result.append(allocator, if (proto.is_main_chunk) @as(u8, 1) else @as(u8, 0));
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
        try writeProto(result, allocator, nested, strip, proto.source);
    }

    // Write debug info (unless stripped)
    if (strip) {
        try writeU32(result, allocator, 0); // source_len
        try writeU32(result, allocator, 0); // lineinfo_count
        try writeU32(result, allocator, 0); // local_reg_names_count
        try writeU32(result, allocator, 0); // upvalue_name_count
    } else {
        // Source name
        const same_as_parent = if (parent_source) |ps|
            std.mem.eql(u8, ps, proto.source)
        else
            false;
        if (same_as_parent) {
            try writeU32(result, allocator, 0);
        } else {
            try writeU32(result, allocator, @intCast(proto.source.len));
            try result.appendSlice(allocator, proto.source);
        }

        // Line info
        try writeU32(result, allocator, @intCast(proto.lineinfo.len));
        for (proto.lineinfo) |line| {
            try writeU32(result, allocator, line);
        }

        // Local register names (needed by debug library after undump)
        try writeU32(result, allocator, @intCast(proto.local_reg_names.len));
        for (proto.local_reg_names) |name_opt| {
            if (name_opt) |name| {
                try writeU32(result, allocator, @intCast(name.len));
                try result.appendSlice(allocator, name);
            } else {
                try writeU32(result, allocator, std.math.maxInt(u32));
            }
        }

        // Upvalue names (needed by debug.getupvalue/setupvalue after undump)
        try writeU32(result, allocator, @intCast(proto.upvalues.len));
        for (proto.upvalues) |upv| {
            if (upv.name) |name| {
                try writeU32(result, allocator, @intCast(name.len));
                try result.appendSlice(allocator, name);
            } else {
                try writeU32(result, allocator, std.math.maxInt(u32));
            }
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

    const format = reader.readU8() orelse return error.InvalidBytecode;
    if (format != FORMAT) return error.InvalidBytecode;

    const luac_data = reader.readBytes(LUAC_DATA.len) orelse return error.InvalidBytecode;
    if (!std.mem.eql(u8, luac_data, LUAC_DATA)) return error.InvalidBytecode;

    const insn_size = reader.readU8() orelse return error.InvalidBytecode;
    const int_size = reader.readU8() orelse return error.InvalidBytecode;
    const num_size = reader.readU8() orelse return error.InvalidBytecode;
    if (insn_size != @sizeOf(Instruction) or int_size != @sizeOf(i64) or num_size != @sizeOf(f64)) {
        return error.InvalidBytecode;
    }

    const luac_int = reader.readI64() orelse return error.InvalidBytecode;
    const luac_num = reader.readF64() orelse return error.InvalidBytecode;
    if (luac_int != LUAC_INT or luac_num != LUAC_NUM) return error.InvalidBytecode;

    // Read proto
    return readProto(&reader, gc, allocator);
}

fn readProto(reader: *ByteReader, gc: anytype, allocator: std.mem.Allocator) !*ProtoObject {
    // Read function header
    const numparams = reader.readU8() orelse return error.InvalidBytecode;
    const is_vararg = (reader.readU8() orelse return error.InvalidBytecode) != 0;
    const is_main_chunk = (reader.readU8() orelse return error.InvalidBytecode) != 0;
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

    const local_name_count = reader.readU32() orelse return error.InvalidBytecode;
    const local_reg_names = if (local_name_count > 0) blk: {
        const names = try allocator.alloc(?[]const u8, local_name_count);
        errdefer allocator.free(names);
        for (names) |*name_opt| {
            const len = reader.readU32() orelse return error.InvalidBytecode;
            if (len == std.math.maxInt(u32)) {
                name_opt.* = null;
            } else {
                const raw = reader.readBytes(len) orelse return error.InvalidBytecode;
                const name = try allocator.alloc(u8, len);
                @memcpy(name, raw);
                name_opt.* = name;
            }
        }
        break :blk names;
    } else &[_]?[]const u8{};

    const upvalue_name_count = reader.readU32() orelse return error.InvalidBytecode;
    if (upvalue_name_count > upvalues.len) return error.InvalidBytecode;
    var upvalue_name_bufs = std.ArrayList([]u8).empty;
    defer {
        if (@errorReturnTrace() != null) {
            for (upvalue_name_bufs.items) |buf| allocator.free(buf);
        }
        upvalue_name_bufs.deinit(allocator);
    }
    var upvalue_idx: usize = 0;
    while (upvalue_idx < upvalue_name_count) : (upvalue_idx += 1) {
        const len = reader.readU32() orelse return error.InvalidBytecode;
        if (len == std.math.maxInt(u32)) {
            upvalues[upvalue_idx].name = null;
            continue;
        }
        const raw = reader.readBytes(len) orelse return error.InvalidBytecode;
        const name = try allocator.alloc(u8, len);
        errdefer allocator.free(name);
        @memcpy(name, raw);
        try upvalue_name_bufs.append(allocator, name);
        upvalues[upvalue_idx].name = name;
    }
    while (upvalue_idx < upvalues.len) : (upvalue_idx += 1) {
        upvalues[upvalue_idx].name = null;
    }

    // Allocate ProtoObject through GC
    const proto_obj = try gc.allocProto(k, code, protos, numparams, is_vararg, is_main_chunk, maxstacksize, nups, upvalues, local_reg_names, source, lineinfo);

    // Fix up nested protos that omitted source (same as this proto).
    if (proto_obj.source.len > 0) {
        try propagateSourceToChildren(proto_obj, allocator);
    }
    return proto_obj;
}

fn propagateSourceToChildren(proto_obj: *ProtoObject, allocator: std.mem.Allocator) !void {
    for (proto_obj.protos) |child| {
        if (child.source.len == 0 and child.lineinfo.len > 0 and proto_obj.source.len > 0) {
            child.source = try allocator.dupe(u8, proto_obj.source);
        }
        if (child.source.len > 0) {
            try propagateSourceToChildren(child, allocator);
        }
    }
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
