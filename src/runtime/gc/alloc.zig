//! GC Allocation Helpers
//!
//! Responsibilities:
//!   - Allocate GC-managed objects (string/table/closure/etc.)
//!   - Track bytes_allocated and trigger GC thresholds
//!   - Initialize GC headers via newObjectHeader

const std = @import("std");
const object = @import("object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;
const ProtoObject = object.ProtoObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;
const ThreadStatus = object.ThreadStatus;
const Upvaldesc = object.Upvaldesc;
const Instruction = @import("../../compiler/opcodes.zig").Instruction;
const NativeFn = @import("../native.zig").NativeFn;
const TValue = @import("../value.zig").TValue;

// Debug: force GC on every allocation to expose marking bugs
// Enable temporarily to test GC correctness
const GC_STRESS_TEST = false;

/// Allocate a new GC-managed object
/// T must be a struct with a 'header: GCObject' field as first member
pub fn allocObject(self: anytype, comptime T: type, extra_bytes: usize) !*T {
    const size = @sizeOf(T) + extra_bytes;

    // Check if GC should run before allocation
    if (GC_STRESS_TEST or self.bytes_allocated + size > self.next_gc) {
        tryCollect(self);
    }

    // Allocate memory
    const memory = try self.allocator.alloc(u8, size);
    const ptr = @as(*T, @ptrCast(@alignCast(memory.ptr)));

    self.bytes_allocated += size;

    return ptr;
}

/// Try to run GC if running, not inhibited, and root providers exist
fn tryCollect(self: anytype) void {
    // Don't run GC if stopped via stop()
    if (!self.is_running) return;
    // Don't run GC if inhibited (during materialization, etc.)
    if (self.gc_inhibit > 0) return;
    // Don't run GC if no root providers registered
    if (self.root_providers.items.len == 0) return;

    self.collect();
}

/// Create a GC header for new object allocation
/// New objects are marked black (current_mark) to survive the current cycle
pub fn newObjectHeader(self: anytype, obj_type: GCObjectType) GCObject {
    return GCObject.initWithMark(obj_type, self.objects, self.current_mark);
}

/// Allocate a new string object
pub fn allocString(self: anytype, str: []const u8) !*StringObject {
    // Check intern table for existing string
    if (self.strings.get(str)) |existing| {
        return existing;
    }

    // Allocate new StringObject
    const obj = try allocObject(self, StringObject, str.len);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .string);
    obj.len = str.len;
    obj.hash = StringObject.hashString(str);

    // Copy string data inline
    @memcpy(obj.data()[0..str.len], str);

    // Add to GC object list
    self.objects = &obj.header;

    // Add to intern table (key is the inline string data)
    try self.strings.put(obj.asSlice(), obj);

    return obj;
}

/// Allocate a new table object
pub fn allocTable(self: anytype) !*TableObject {
    const obj = try allocObject(self, TableObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .table);
    // TODO: Use tracking allocator for HashMap memory accounting
    // Currently disabled due to potential GC interaction issues
    obj.hash_part = TableObject.HashMap.init(self.allocator);
    obj.allocator = self.allocator;
    obj.metatable = null; // No metatable by default

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new closure object with upvalues array
pub fn allocClosure(self: anytype, proto: *ProtoObject) !*ClosureObject {
    const obj = try allocObject(self, ClosureObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .closure);
    obj.proto = proto;

    // Allocate upvalues array if needed
    if (proto.nups > 0) {
        const upvals = try self.allocator.alloc(*UpvalueObject, proto.nups);
        obj.upvalues = upvals;
        self.bytes_allocated += proto.nups * @sizeOf(*UpvalueObject);
    } else {
        obj.upvalues = &.{};
    }

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new proto object
/// Creates a GC-managed function prototype from materialized data
pub fn allocProto(
    self: anytype,
    k: []const TValue,
    code: []const Instruction,
    protos: []const *ProtoObject,
    numparams: u8,
    is_vararg: bool,
    maxstacksize: u8,
    nups: u8,
    upvalues: []const Upvaldesc,
    source: []const u8,
    lineinfo: []const u32,
) !*ProtoObject {
    const obj = try allocObject(self, ProtoObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .proto);
    obj.k = k;
    obj.code = code;
    obj.protos = protos;
    obj.numparams = numparams;
    obj.is_vararg = is_vararg;
    obj.maxstacksize = maxstacksize;
    obj.nups = nups;
    obj.upvalues = upvalues;
    obj.allocator = self.allocator;
    obj.source = source;
    obj.lineinfo = lineinfo;

    // Track memory for arrays (allocated by materialize)
    self.bytes_allocated += k.len * @sizeOf(TValue);
    self.bytes_allocated += code.len * @sizeOf(Instruction);
    self.bytes_allocated += protos.len * @sizeOf(*ProtoObject);
    self.bytes_allocated += upvalues.len * @sizeOf(Upvaldesc);
    self.bytes_allocated += source.len;
    self.bytes_allocated += lineinfo.len * @sizeOf(u32);

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new upvalue object
pub fn allocUpvalue(self: anytype, location: *TValue) !*UpvalueObject {
    const obj = try allocObject(self, UpvalueObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .upvalue);
    obj.location = location;
    obj.closed = TValue.nil;
    obj.next_open = null;

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new closed upvalue with a specific value
/// Used for _ENV in load() and similar cases where the upvalue doesn't reference the stack
pub fn allocClosedUpvalue(self: anytype, value: TValue) !*UpvalueObject {
    const obj = try allocObject(self, UpvalueObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .upvalue);
    obj.closed = value;
    obj.location = &obj.closed; // Point to self (closed state)
    obj.next_open = null;

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new native closure object
pub fn allocNativeClosure(self: anytype, func: NativeFn) !*NativeClosureObject {
    const obj = try allocObject(self, NativeClosureObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .native_closure);
    obj.func = func;

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new userdata object
/// data_size: size of the raw data block in bytes
/// num_user_values: number of user values (0-255)
pub fn allocUserdata(self: anytype, data_size: usize, num_user_values: u8) !*UserdataObject {
    const extra = @as(usize, num_user_values) * @sizeOf(TValue) + data_size;
    const obj = try allocObject(self, UserdataObject, extra);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .userdata);
    obj.size = data_size;
    obj.nuvalue = num_user_values;
    obj.metatable = null;

    // Initialize user values to nil
    const uvals = obj.userValues();
    for (uvals) |*uv| {
        uv.* = TValue.nil;
    }

    // Zero-initialize data block
    @memset(obj.dataSlice(), 0);

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}

/// Allocate a new thread object (coroutine wrapper)
/// vm_ptr: pointer to VM execution state (passed as anyopaque to avoid circular import)
/// status: initial thread status (usually .suspended for coroutines)
pub fn allocThread(
    self: anytype,
    vm_ptr: *anyopaque,
    status: ThreadStatus,
    mark_vm: ?*const fn (*anyopaque, *anyopaque) void,
    free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void,
) !*ThreadObject {
    const obj = try allocObject(self, ThreadObject, 0);

    // Initialize GC header (black = survives current cycle)
    obj.header = newObjectHeader(self, .thread);
    obj.status = status;
    obj.vm = vm_ptr;
    obj.mark_vm = mark_vm;
    obj.free_vm = free_vm;

    // Add to GC object list
    self.objects = &obj.header;

    return obj;
}
