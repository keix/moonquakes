//! GC Object System
//!
//! All heap-allocated Lua values inherit from GCObject.
//! Uniform header enables polymorphic GC traversal.
//!
//! Object types:
//!   - StringObject: interned, immutable, hash cached
//!   - TableObject: hash + array hybrid (Lua table)
//!   - ClosureObject: function + captured upvalues
//!   - NativeClosureObject: C/Zig function + upvalues
//!   - UpvalueObject: open (stack ref) or closed (own storage)
//!   - ProtoObject: compiled bytecode (function prototype)
//!   - ThreadObject: coroutine state (VM reference)
//!   - UserdataObject: C-managed memory with optional metatable
//!
//! Layout invariant:
//!   Every object struct starts with GCObject header.
//!   @fieldParentPtr enables safe downcasting from header to concrete type.

const std = @import("std");
const proto_mod = @import("../../compiler/proto.zig");
pub const Instruction = @import("../../compiler/opcodes.zig").Instruction;
pub const Upvaldesc = proto_mod.Upvaldesc;

/// Types of GC-managed objects
pub const GCObjectType = enum(u8) {
    string,
    table,
    closure,
    native_closure,
    upvalue,
    userdata,
    proto,
    thread,
    file,
};

/// Common header for all GC-managed objects
///
/// This header must be the first field in every GC object struct.
/// It provides the infrastructure for mark-and-sweep collection.
///
/// Tri-color abstraction for incremental GC:
///   White: mark_bit != GC.current_mark (unreachable, potentially garbage)
///   Gray:  mark_bit == GC.current_mark AND in_gray == true (reachable, children not scanned)
///   Black: mark_bit == GC.current_mark AND in_gray == false (reachable, fully scanned)
pub const GCObject = struct {
    /// Object type for dispatch in mark/sweep phases
    type: GCObjectType,

    /// Mark bit for garbage collection (flip mark scheme)
    /// Compared with GC.current_mark to determine reachability
    mark_bit: bool,

    /// Gray list membership flag
    /// true = in gray list (awaiting child scan)
    in_gray: bool = false,

    /// Linked list pointer for tracking all objects
    /// The GC maintains a list of all allocated objects
    next: ?*GCObject,

    /// Gray list link for incremental marking
    gray_next: ?*GCObject = null,

    /// True if object has a pending __gc finalizer in the queue
    finalizer_queued: bool = false,

    /// Initialize a GC object header
    pub fn init(object_type: GCObjectType, next_obj: ?*GCObject) GCObject {
        return .{
            .type = object_type,
            .mark_bit = false,
            .in_gray = false,
            .next = next_obj,
            .gray_next = null,
            .finalizer_queued = false,
        };
    }

    /// Initialize with specific mark bit (for incremental GC)
    pub fn initWithMark(object_type: GCObjectType, next_obj: ?*GCObject, mark_value: bool) GCObject {
        return .{
            .type = object_type,
            .mark_bit = mark_value,
            .in_gray = false,
            .next = next_obj,
            .gray_next = null,
            .finalizer_queued = false,
        };
    }

    /// Mark this object as reachable (legacy, for compatibility)
    pub fn mark(self: *GCObject) void {
        self.mark_bit = true;
    }

    /// Clear the mark (for next collection cycle)
    pub fn unmark(self: *GCObject) void {
        self.mark_bit = false;
    }

    /// Check if object is marked (legacy, use GC.isMarked for flip mark)
    pub fn isMarkedLegacy(self: *const GCObject) bool {
        return self.mark_bit;
    }
};

/// String Object - GC-managed immutable strings
///
/// StringObject stores string data inline after the struct.
/// Layout: [GCObject header][len][hash][string bytes...]
pub const StringObject = struct {
    header: GCObject,
    len: usize,
    hash: u32, // FNV-1a hash for fast comparison and table keys

    /// Get pointer to the string data (stored inline after struct)
    pub fn data(self: *StringObject) [*]u8 {
        const base = @intFromPtr(self);
        const offset = @sizeOf(StringObject);
        return @ptrFromInt(base + offset);
    }

    /// Get string as a slice
    pub fn asSlice(self: *const StringObject) []const u8 {
        const ptr = @as(*StringObject, @constCast(self));
        return ptr.data()[0..self.len];
    }

    /// Calculate hash using FNV-1a algorithm
    pub fn hashString(str: []const u8) u32 {
        var hash: u32 = 2166136261; // FNV offset basis
        for (str) |byte| {
            hash ^= byte;
            hash *%= 16777619; // FNV prime
        }
        return hash;
    }
};

/// Table Object - GC-managed Lua table
///
/// Supports any TValue as key (Lua 5.4 compatible).
/// Keys can be: strings, numbers, booleans, tables, functions, userdata.
/// nil cannot be a key (Lua semantics).
pub const TableObject = struct {
    const TValue = @import("../value.zig").TValue;

    /// Custom hash context for TValue keys
    /// Supports all Lua key types: strings, numbers, booleans, objects
    pub const TValueKeyContext = struct {
        pub fn hash(_: TValueKeyContext, key: TValue) u64 {
            return switch (key) {
                .nil => 0, // nil can't be a key, but need a hash for HashMap
                .boolean => |b| if (b) 1 else 2,
                .integer => |i| @bitCast(i),
                .number => |n| blk: {
                    // Check if float is actually an integer value
                    if (n == @floor(n) and n >= -9007199254740992 and n <= 9007199254740992) {
                        // Use same hash as integer for int-representable floats
                        const as_int: i64 = @intFromFloat(n);
                        break :blk @bitCast(as_int);
                    }
                    break :blk @bitCast(n);
                },
                .object => |obj| blk: {
                    if (obj.type == .string) {
                        // Use string's pre-computed hash for consistency
                        const str: *StringObject = @fieldParentPtr("header", obj);
                        break :blk str.hash;
                    }
                    // For other objects, use pointer as hash
                    break :blk @intFromPtr(obj);
                },
            };
        }

        pub fn eql(_: TValueKeyContext, a: TValue, b: TValue) bool {
            return a.eql(b);
        }
    };

    pub const HashMap = std.HashMap(
        TValue,
        TValue,
        TValueKeyContext,
        std.hash_map.default_max_load_percentage,
    );
    pub const KeyIndexMap = std.HashMap(
        TValue,
        u32,
        TValueKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    /// Stores keys explicitly deleted from this table.
    /// This allows `next(t, k)` to continue iteration when `k` was
    /// removed during traversal, while still rejecting arbitrary invalid keys.
    pub const DeletedKeySet = std.HashMap(
        TValue,
        void,
        TValueKeyContext,
        std.hash_map.default_max_load_percentage,
    );
    pub const KeyValuePair = struct {
        key: TValue,
        value: TValue,
    };
    pub const NextSlotError = error{ InvalidKey, OutOfMemory };

    fn floatToExactIntKey(n: f64) ?i64 {
        if (!std.math.isFinite(n) or n != @floor(n)) return null;
        const max_i = std.math.maxInt(i64);
        const min_i = std.math.minInt(i64);
        const max_f: f64 = @floatFromInt(max_i);
        const min_f: f64 = @floatFromInt(min_i);
        if (n < min_f or n > max_f) return null;
        const i: i64 = @intFromFloat(n);
        if (@as(f64, @floatFromInt(i)) != n) return null;
        return i;
    }

    fn canonicalizeLookupKey(key: TValue) TValue {
        return switch (key) {
            .number => |n| blk: {
                if (floatToExactIntKey(n)) |i| break :blk TValue{ .integer = i };
                break :blk key;
            },
            else => key,
        };
    }

    fn canonicalizeStoreKey(self: *const TableObject, key: TValue) TValue {
        const lookup_key = canonicalizeLookupKey(key);
        // Preserve Lua behavior for numeric keys: if a number key compares equal
        // to an existing integer key, update that integer slot.
        if (lookup_key == .number) {
            const n = lookup_key.number;
            var iter = self.hash_part.iterator();
            while (iter.next()) |entry| {
                if (entry.key_ptr.* == .integer) {
                    const i = entry.key_ptr.*.integer;
                    const as_num: f64 = @floatFromInt(i);
                    if (as_num == n) return TValue{ .integer = i };
                }
            }
        }
        return lookup_key;
    }

    /// Weak table mode for __mode metamethod
    pub const WeakMode = enum(u2) {
        none = 0, // Strong table (default)
        weak_keys = 1, // __mode contains 'k'
        weak_values = 2, // __mode contains 'v'
        weak_both = 3, // __mode contains both 'k' and 'v'
    };

    header: GCObject,
    hash_part: HashMap,
    deleted_keys: DeletedKeySet,
    iter_keys: std.ArrayListUnmanaged(TValue),
    iter_index: KeyIndexMap,
    mod_count: u64 = 0,
    iter_cache_mod_count: u64 = std.math.maxInt(u64),
    allocator: std.mem.Allocator,
    seq_len: i64 = 0,
    /// Metatable for metamethod dispatch (null if no metatable)
    metatable: ?*TableObject,
    /// Weak mode, cached from metatable.__mode during GC cycle
    weak_mode: WeakMode = .none,

    /// Check if this table has weak keys
    pub fn hasWeakKeys(self: *const TableObject) bool {
        return self.weak_mode == .weak_keys or self.weak_mode == .weak_both;
    }

    /// Check if this table has weak values
    pub fn hasWeakValues(self: *const TableObject) bool {
        return self.weak_mode == .weak_values or self.weak_mode == .weak_both;
    }

    /// Get a value by TValue key
    pub fn get(self: *const TableObject, key: TValue) ?TValue {
        const canonical_key = canonicalizeLookupKey(key);
        if (self.hash_part.get(canonical_key)) |v| return v;
        return null;
    }

    pub fn rawLen(self: *const TableObject) i64 {
        return self.seq_len;
    }

    fn isPureArray(self: *const TableObject) bool {
        return self.seq_len > 0 and @as(usize, @intCast(self.seq_len)) == self.hash_part.count();
    }

    fn keyLessThan(a: TValue, b: TValue) bool {
        const ta = std.meta.activeTag(a);
        const tb = std.meta.activeTag(b);
        if (ta != tb) return @intFromEnum(ta) < @intFromEnum(tb);

        return switch (a) {
            .nil => false,
            .boolean => |ab| (!ab) and b.boolean,
            .integer => |ai| ai < b.integer,
            .number => |an| an < b.number,
            .object => |ao| blk: {
                const bo = b.object;
                if (ao.type != bo.type) break :blk @intFromEnum(ao.type) < @intFromEnum(bo.type);
                break :blk @intFromPtr(ao) < @intFromPtr(bo);
            },
        };
    }

    fn selectNext(self: *const TableObject, after: ?TValue) ?KeyValuePair {
        var iter = self.hash_part.iterator();
        var best_key: ?TValue = null;
        var best_val: TValue = .nil;

        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value.isNil()) continue;
            if (after) |pivot| {
                if (!keyLessThan(pivot, key)) continue;
            }
            if (best_key == null or keyLessThan(key, best_key.?)) {
                best_key = key;
                best_val = value;
            }
        }

        if (best_key) |key| return .{ .key = key, .value = best_val };
        return null;
    }

    fn rebuildIterCache(self: *TableObject) !void {
        self.iter_keys.clearRetainingCapacity();
        self.iter_index.clearRetainingCapacity();

        var iter = self.hash_part.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value.isNil()) continue;
            try self.iter_keys.append(self.allocator, key);
        }

        const SortCtx = struct {
            fn lessThan(_: void, a: TValue, b: TValue) bool {
                return keyLessThan(a, b);
            }
        };
        std.mem.sort(TValue, self.iter_keys.items, {}, SortCtx.lessThan);

        for (self.iter_keys.items, 0..) |key, i| {
            try self.iter_index.put(key, @intCast(i));
        }
        self.iter_cache_mod_count = self.mod_count;
    }

    fn keyExactEq(a: TValue, b: TValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .nil => true,
            .boolean => |v| v == b.boolean,
            .integer => |v| v == b.integer,
            .number => |v| v == b.number,
            .object => |v| v == b.object,
        };
    }

    fn hasExactKey(self: *const TableObject, target: TValue) bool {
        var iter = self.hash_part.iterator();
        while (iter.next()) |entry| {
            if (keyExactEq(entry.key_ptr.*, target)) return true;
        }
        return false;
    }

    fn hasExactDeletedKey(self: *const TableObject, target: TValue) bool {
        var iter = self.deleted_keys.iterator();
        while (iter.next()) |entry| {
            if (keyExactEq(entry.key_ptr.*, target)) return true;
        }
        return false;
    }

    fn pruneDeletedKeys(self: *TableObject) void {
        const deleted_count = self.deleted_keys.count();
        const live_count = self.hash_part.count();
        if (deleted_count > (live_count * 2 + 64)) {
            self.deleted_keys.clearRetainingCapacity();
        }
    }

    pub fn nextSlot(self: *TableObject, prev: ?TValue) NextSlotError!?KeyValuePair {
        if (self.isPureArray()) {
            if (prev == null) {
                var i: i64 = 1;
                while (i <= self.seq_len) : (i += 1) {
                    const key = TValue{ .integer = i };
                    if (self.get(key)) |v| {
                        if (!v.isNil()) return .{ .key = key, .value = v };
                    }
                }
                return null;
            }
            const prev_key = prev.?;
            if (prev_key == .integer and prev_key.integer >= 1 and prev_key.integer <= self.seq_len) {
                var i: i64 = prev_key.integer + 1;
                while (i <= self.seq_len) : (i += 1) {
                    const key = TValue{ .integer = i };
                    if (self.get(key)) |v| {
                        if (!v.isNil()) return .{ .key = key, .value = v };
                    }
                }
                return null;
            }
        }

        if (self.iter_cache_mod_count != self.mod_count) {
            try self.rebuildIterCache();
        }

        if (prev == null) {
            for (self.iter_keys.items) |key| {
                if (self.hash_part.get(key)) |value| {
                    if (!value.isNil()) return .{ .key = key, .value = value };
                }
            }
            return null;
        }
        const prev_key = prev.?;

        if (self.iter_index.get(prev_key)) |pos| {
            var i: usize = @as(usize, @intCast(pos)) + 1;
            while (i < self.iter_keys.items.len) : (i += 1) {
                const key = self.iter_keys.items[i];
                if (self.hash_part.get(key)) |value| {
                    if (!value.isNil()) return .{ .key = key, .value = value };
                }
            }
            return null;
        }

        if (self.hasExactKey(prev_key)) return self.selectNext(prev_key);

        if (self.hasExactDeletedKey(prev_key)) {
            _ = self.deleted_keys.remove(prev_key);
            return self.selectNext(prev_key);
        }

        return error.InvalidKey;
    }

    /// Set a value by TValue key
    /// Note: nil and NaN keys are not allowed (Lua 5.4 semantics)
    pub fn set(self: *TableObject, key: TValue, value: TValue) !void {
        // TODO(gc): When enabling true incremental/generational collection,
        // route table mutations through a write barrier helper here.
        if (key.isNil()) return error.InvalidTableKey;
        if (key == .number and std.math.isNan(key.number)) return error.InvalidTableKey;
        const canonical_key = canonicalizeStoreKey(self, key);
        const seq_key: ?i64 = switch (canonical_key) {
            .integer => |i| if (i > 0) i else null,
            else => null,
        };

        // Setting to nil removes the entry
        if (value.isNil()) {
            if (self.hash_part.contains(canonical_key)) {
                _ = self.hash_part.remove(canonical_key);
                try self.deleted_keys.put(canonical_key, {});
                self.mod_count +%= 1;
                self.pruneDeletedKeys();
                if (seq_key) |k| {
                    if (k == self.seq_len) {
                        while (self.seq_len > 0) {
                            const prev_key = TValue{ .integer = self.seq_len };
                            if (self.hash_part.get(prev_key) != null) break;
                            self.seq_len -= 1;
                        }
                    }
                }
            }
        } else {
            try self.hash_part.put(canonical_key, value);
            _ = self.deleted_keys.remove(canonical_key);
            self.mod_count +%= 1;
            if (seq_key) |k| {
                if (k == self.seq_len + 1) {
                    var cursor = self.seq_len + 1;
                    while (true) : (cursor += 1) {
                        const next_key = TValue{ .integer = cursor };
                        if (self.hash_part.get(next_key) == null) break;
                    }
                    self.seq_len = cursor - 1;
                }
            }
        }
    }

    /// Clean up internal data structures (called by GC during sweep)
    pub fn deinit(self: *TableObject) void {
        self.iter_index.deinit();
        self.iter_keys.deinit(self.allocator);
        self.deleted_keys.deinit();
        self.hash_part.deinit();
    }
};

/// Closure Object - GC-managed function instance
///
/// Wraps a ProtoObject (bytecode) with upvalues for captured variables.
pub const ClosureObject = struct {
    header: GCObject,
    proto: *ProtoObject,
    upvalues: []*UpvalueObject,

    /// Get the underlying ProtoObject
    pub fn getProto(self: *const ClosureObject) *ProtoObject {
        return self.proto;
    }
};

/// Native Closure Object - GC-managed native function
///
/// Wraps a native function pointer. Reachable while referenced from
/// globals/registry or other GC-managed objects, and collected when unreachable.
pub const NativeClosureObject = struct {
    const NativeFn = @import("../native.zig").NativeFn;

    header: GCObject,
    func: NativeFn,

    /// Get the native function
    pub fn getFunc(self: *const NativeClosureObject) NativeFn {
        return self.func;
    }
};

/// Upvalue Object - GC-managed captured variable
///
/// Upvalues capture variables from enclosing scopes for closures.
/// - "Open" upvalue: location points to a stack slot (variable still on stack)
/// - "Closed" upvalue: location points to self.closed (stack frame popped)
pub const UpvalueObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Pointer to the value (stack slot when open, &closed when closed)
    location: *TValue,
    /// Owning thread while open; null after close.
    owner_thread: ?*ThreadObject,
    /// Storage for the value when the upvalue is closed
    closed: TValue,
    /// Linked list of open upvalues (for efficient closing when stack frame pops)
    next_open: ?*UpvalueObject,

    /// Check if this upvalue is closed
    pub fn isClosed(self: *const UpvalueObject) bool {
        return self.location == &@constCast(self).closed;
    }

    /// Close this upvalue: copy the value and point to internal storage
    pub fn close(self: *UpvalueObject) void {
        self.closed = self.location.*;
        self.location = &self.closed;
        self.owner_thread = null;
    }

    /// Get the current value
    pub fn get(self: *const UpvalueObject) TValue {
        return self.location.*;
    }

    /// Set the value
    pub fn set(self: *UpvalueObject, value: TValue) void {
        self.location.* = value;
    }
};

/// Proto Object - GC-managed function prototype
///
/// Contains bytecode, constants, and metadata for Lua functions.
/// Previously allocated via raw allocator, now GC-managed for proper lifecycle.
///
/// Lua semantics: Proto contains TValues (constants) and nested ProtoObjects,
/// forming a tree structure that must be traced by GC.
pub const ProtoObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Constants table (may contain GC objects like strings)
    k: []const TValue,
    /// Bytecode instructions
    code: []const Instruction,
    /// Nested function prototypes (GC-managed)
    protos: []const *ProtoObject,
    /// Number of fixed parameters
    numparams: u8,
    /// Whether function accepts varargs
    is_vararg: bool,
    /// Whether this proto is a main chunk, even if called from another frame
    is_main_chunk: bool = false,
    /// Maximum stack size needed
    maxstacksize: u8,
    /// Number of upvalues
    nups: u8,
    /// Upvalue descriptors
    upvalues: []const Upvaldesc,
    /// Best-effort local names by register index (for diagnostics)
    local_reg_names: []const ?[]const u8 = &.{},

    /// Allocator used to allocate k, code, protos, upvalues arrays
    /// Needed for deallocation during GC sweep
    allocator: std.mem.Allocator,

    // Debug/error info
    /// Source name (e.g., "@file.lua" or "[string \"...\"]")
    source: []const u8 = "",
    /// Line number for each instruction
    lineinfo: []const u32 = &.{},
};

/// Userdata Object - GC-managed arbitrary data block
///
/// Full userdata in Lua 5.4:
/// - Raw memory block of arbitrary size
/// - Optional metatable for metamethod dispatch
/// - Up to 255 "user values" (TValues associated with the userdata)
///
/// Memory layout: [UserdataObject header][nuvalue * TValue][size bytes]
pub const UserdataObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Size of the raw data block in bytes
    size: usize,
    /// Number of user values (0-255)
    nuvalue: u8,
    /// Optional metatable for metamethod dispatch
    metatable: ?*TableObject,

    /// Get the user values array (stored inline after struct)
    pub fn userValues(self: *UserdataObject) []TValue {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject);
        const ptr: [*]TValue = @ptrFromInt(base + offset);
        return ptr[0..self.nuvalue];
    }

    /// Get the user values array (const version)
    pub fn userValuesConst(self: *const UserdataObject) []const TValue {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject);
        const ptr: [*]const TValue = @ptrFromInt(base + offset);
        return ptr[0..self.nuvalue];
    }

    /// Get pointer to the raw data block (stored after user values)
    pub fn data(self: *UserdataObject) [*]u8 {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject) + self.nuvalue * @sizeOf(TValue);
        return @ptrFromInt(base + offset);
    }

    /// Get data as a slice
    pub fn dataSlice(self: *UserdataObject) []u8 {
        return self.data()[0..self.size];
    }

    /// Calculate total allocation size for a userdata
    pub fn allocationSize(data_size: usize, num_user_values: u8) usize {
        return @sizeOf(UserdataObject) + @as(usize, num_user_values) * @sizeOf(TValue) + data_size;
    }
};

/// Thread Status for coroutines
pub const ThreadStatus = enum(u8) {
    created, // Created and never resumed yet (internal)
    suspended, // Yielded, ready to be resumed
    running, // Currently executing
    normal, // Resumed another coroutine (waiting for it to finish)
    dead, // Finished execution or errored
};

/// Thread Object - GC-managed coroutine/thread
///
/// Represents a Lua thread (coroutine). Each thread has its own execution
/// state (stack, call stack, etc.) but shares the global environment with
/// other threads via Runtime.
///
/// The main thread is also a ThreadObject, returned by coroutine.running().
pub const ThreadObject = struct {
    header: GCObject,

    /// Coroutine status
    status: ThreadStatus,

    /// Pointer to VM execution state (actually *VM, using anyopaque to avoid circular import)
    /// The VM contains: stack, top, base, ci, callstack, open_upvalues, etc.
    vm: *anyopaque,

    /// Entry function object for first resume.
    /// Kept on the thread object so wrapper logic does not depend on VM stack layout.
    entry_func: ?*GCObject = null,

    /// Callback to mark VM roots (stack, callframes, upvalues, etc.)
    /// Set by VM.init. GC calls this during mark phase for coroutine threads.
    /// Main thread is marked via its RootProvider registration.
    /// Signature: fn(vm: *anyopaque, gc: *anyopaque) void
    /// Uses anyopaque for GC to avoid circular import with gc.zig.
    mark_vm: ?*const fn (*anyopaque, *anyopaque) void = null,

    /// Callback to free VM memory.
    /// Set by VM.init. GC calls this during sweep phase for coroutine threads.
    /// Main thread is freed by Runtime.deinit, not by GC.
    free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    /// Get VM pointer (casts from anyopaque)
    pub fn getVM(self: *ThreadObject) *anyopaque {
        return self.vm;
    }
};

/// File kind for FileObject
pub const FileKind = enum(u8) {
    file, // Regular disk file
    stdout, // Standard output
    stderr, // Standard error
    stdin, // Standard input
    popen, // Process pipe
};

/// Buffering mode for FileObject
pub const BufMode = enum(u8) {
    full, // Flush on close or explicit flush
    line, // Flush on newline
    no, // Flush immediately (unbuffered)
};

/// File Object - GC-managed file handle
///
/// Represents a Lua FILE* handle with proper ownership and buffering.
/// Unified representation for stdio (stdout/stderr/stdin) and regular files.
///
/// Memory layout: [FileObject header][buffer bytes...]
/// Buffer is managed via std.ArrayList to support dynamic growth.
pub const FileObject = struct {
    header: GCObject,
    /// Kind of file (regular file, stdio, or pipe)
    kind: FileKind,
    /// Buffering mode
    bufmode: BufMode,
    /// Internal write buffer (Unmanaged for explicit allocator control)
    buffer: std.ArrayListUnmanaged(u8),
    /// Allocator for buffer operations
    allocator: std.mem.Allocator,
    /// OS file handle (null for stdio, which uses std.fs directly)
    handle: ?std.fs.File,
    /// Whether the file has been closed
    closed: bool,
    /// Filename for error messages (null for stdio)
    filename: ?*StringObject,
    /// File mode string (e.g., "r", "w", "a")
    mode: ?*StringObject,
    /// Metatable for file methods (write, read, close, etc.)
    metatable: ?*TableObject,

    /// Initialize a FileObject for stdio
    pub fn initStdio(allocator: std.mem.Allocator, kind: FileKind, next_obj: ?*GCObject) FileObject {
        const bufmode: BufMode = switch (kind) {
            .stdout => .line,
            .stderr => .no,
            .stdin => .no,
            else => .full,
        };
        return .{
            .header = GCObject.init(.file, next_obj),
            .kind = kind,
            .bufmode = bufmode,
            .buffer = .{},
            .allocator = allocator,
            .handle = null, // stdio uses std.fs.File.stdout() etc. directly
            .closed = false,
            .filename = null,
            .mode = null,
            .metatable = null,
        };
    }

    /// Initialize a FileObject for a regular file
    pub fn initFile(allocator: std.mem.Allocator, handle: std.fs.File, next_obj: ?*GCObject) FileObject {
        return .{
            .header = GCObject.init(.file, next_obj),
            .kind = .file,
            .bufmode = .full,
            .allocator = allocator,
            .metatable = null,
            .buffer = .{},
            .handle = handle,
            .closed = false,
            .filename = null,
            .mode = null,
        };
    }

    /// Write data to the file (buffered according to bufmode)
    /// Buffer is always the source of truth - all writes go through buffer first,
    /// then bufmode decides when to flush to OS.
    pub fn write(self: *FileObject, data: []const u8) !void {
        if (self.closed) return error.FileClosed;

        // All writes go to buffer first
        try self.buffer.appendSlice(self.allocator, data);

        // bufmode decides when to flush
        switch (self.bufmode) {
            .no => try self.flush(), // Unbuffered: flush immediately
            .line => {
                // Line buffered: flush on newline
                if (std.mem.lastIndexOfScalar(u8, data, '\n') != null) {
                    try self.flush();
                }
            },
            .full => {}, // Fully buffered: wait for explicit flush
        }
    }

    /// Flush buffered data to the destination
    pub fn flush(self: *FileObject) !void {
        if (self.closed) return error.FileClosed;
        if (self.buffer.items.len == 0) return;

        try self.flushData(self.buffer.items);
        self.buffer.clearRetainingCapacity();
    }

    /// Internal: write data directly to destination
    fn flushData(self: *FileObject, data: []const u8) !void {
        const file = switch (self.kind) {
            .stdout => std.fs.File.stdout(),
            .stderr => std.fs.File.stderr(),
            .stdin => return error.WriteError, // Can't write to stdin
            .file, .popen => self.handle orelse return error.WriteError,
        };
        file.writeAll(data) catch return error.WriteError;
    }

    /// Close the file
    pub fn close(self: *FileObject) !void {
        if (self.closed) return error.FileClosed;

        // Flush any remaining buffer
        self.flush() catch {};

        // Close the OS handle for regular files
        if (self.kind == .file or self.kind == .popen) {
            if (self.handle) |h| {
                h.close();
            }
        }

        self.closed = true;
    }

    /// Clean up resources (called by GC during sweep)
    pub fn deinit(self: *FileObject) void {
        // Close file if still open
        if (!self.closed) {
            self.close() catch {};
        }
        // Free the buffer
        self.buffer.deinit(self.allocator);
    }

    /// Check if this is a stdio handle (stdout, stderr, stdin)
    pub fn isStdio(self: *const FileObject) bool {
        return self.kind == .stdout or self.kind == .stderr or self.kind == .stdin;
    }
};

/// Utility functions for working with GC objects
/// Get the concrete object from a GCObject header
///
/// Example usage:
/// ```zig
/// const str_obj = getObject(StringObject, gc_obj);
/// ```
pub fn getObject(comptime T: type, header: *GCObject) *T {
    return @fieldParentPtr("header", header);
}

/// Calculate the size of a GC object including extra data
pub fn objectSize(comptime T: type, extra_bytes: usize) usize {
    return @sizeOf(T) + extra_bytes;
}

/// Validate that a type is a valid GC object (has header field)
pub fn validateGCObject(comptime T: type) void {
    if (!@hasField(T, "header")) {
        @compileError("GC object type must have 'header: GCObject' as first field");
    }

    const header_field = @typeInfo(T).Struct.fields[0];
    if (!std.mem.eql(u8, header_field.name, "header")) {
        @compileError("GC object 'header' must be the first field");
    }

    if (header_field.type != GCObject) {
        @compileError("GC object header field must be of type GCObject");
    }
}
