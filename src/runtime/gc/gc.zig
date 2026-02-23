//! Garbage Collector - Mark and Sweep
//!
//! Non-moving, threshold-based collector.
//! All GC objects share a common header (GCObject) for uniform traversal.
//!
//! Design choices:
//!   - Non-moving: pointers remain stable (C API friendly)
//!   - Threshold-based: collect when bytes_allocated > threshold
//!   - String interning: deduplicated via hash table
//!   - Root providers: VM and Runtime register as marking roots
//!
//! Collection phases:
//!   1. Mark: traverse from roots, set marked=true
//!   2. Sweep: free unmarked objects, reset marks
//!
//! Memory tracking:
//!   - All allocations go through tracking allocator
//!   - bytes_allocated updated on alloc/free/resize

const std = @import("std");
const builtin = @import("builtin");
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
const call = @import("../../vm/call.zig");
const metamethod = @import("../../vm/metamethod.zig");
const MetaEvent = metamethod.MetaEvent;
const SharedMetatables = metamethod.SharedMetatables;
const MetamethodKeys = metamethod.MetamethodKeys;

// Initial GC threshold - collection runs when bytes_allocated exceeds this
// After collection, threshold adjusts based on survival rate (gc_multiplier)
const GC_THRESHOLD = 64 * 1024; // 64KB initial threshold

/// VTable for tracking allocator (uses GC as context directly)
const tracking_vtable = std.mem.Allocator.VTable{
    .alloc = trackingAlloc,
    .resize = trackingResize,
    .remap = trackingRemap,
    .free = trackingFree,
};

fn trackingAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const gc: *GC = @ptrCast(@alignCast(ctx));
    const result = gc.allocator.rawAlloc(len, alignment, ret_addr);
    if (result != null) {
        gc.bytes_allocated += len;
    }
    return result;
}

fn trackingResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const gc: *GC = @ptrCast(@alignCast(ctx));
    const old_len = buf.len;
    const success = gc.allocator.rawResize(buf, alignment, new_len, ret_addr);
    if (success) {
        if (new_len > old_len) {
            gc.bytes_allocated += (new_len - old_len);
        } else {
            gc.bytes_allocated -= (old_len - new_len);
        }
    }
    return success;
}

fn trackingRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const gc: *GC = @ptrCast(@alignCast(ctx));
    const old_len = buf.len;
    const result = gc.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    if (result != null) {
        if (new_len > old_len) {
            gc.bytes_allocated += (new_len - old_len);
        } else {
            gc.bytes_allocated -= (old_len - new_len);
        }
    }
    return result;
}

fn trackingFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const gc: *GC = @ptrCast(@alignCast(ctx));
    gc.bytes_allocated -= buf.len;
    gc.allocator.rawFree(buf, alignment, ret_addr);
}

/// Type-safe interface for root providers (VM, REPL, test harnesses, etc.)
/// Replaces the unsafe ?*anyopaque pattern with a proper vtable-based interface.
/// GC can have multiple root providers, each responsible for marking its own roots.
pub const RootProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Mark all roots owned by this provider (stack, globals, etc.)
        markRoots: *const fn (ctx: *anyopaque, gc: *GC) void,
        /// Call a Lua value (for __gc finalizers). Returns first result or nil.
        callValue: *const fn (ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue,
    };

    /// Type-safe constructor - prevents mismatched ptr/vtable pairs
    pub fn init(comptime T: type, ptr: *T, vtable: *const VTable) RootProvider {
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = vtable,
        };
    }

    pub fn markRoots(self: RootProvider, gc: *GC) void {
        self.vtable.markRoots(self.ptr, gc);
    }

    pub fn callValue(self: RootProvider, func: *const TValue, args: []const TValue) !TValue {
        return self.vtable.callValue(self.ptr, func, args);
    }
};

/// Moonquakes Mark & Sweep Garbage Collector
///
/// This is a simple, non-incremental mark-and-sweep collector.
/// It replaces the arena allocator for automatic memory management.
pub const GC = struct {
    /// System allocator for actual memory allocation
    allocator: std.mem.Allocator,

    /// Linked list of all GC-managed objects
    objects: ?*GCObject,

    /// String intern table for deduplication
    /// Maps string content to existing StringObject for pointer equality
    strings: std.StringHashMap(*StringObject),

    /// Total bytes currently allocated
    bytes_allocated: usize,

    /// Threshold for triggering next collection
    next_gc: usize,

    /// Root providers for marking during GC
    /// Each provider is responsible for marking its own roots (stack, globals, etc.)
    /// Multiple providers supported for VM, REPL, test harnesses, etc.
    root_providers: std.ArrayListUnmanaged(RootProvider),

    // GC tuning parameters
    gc_multiplier: f64 = 2.0, // Heap growth factor
    gc_min_threshold: usize = GC_THRESHOLD,

    /// Counter to inhibit GC during sensitive operations (materialization, etc.)
    /// When > 0, GC will not run automatically
    gc_inhibit: u32 = 0,

    /// List of weak tables found during mark phase
    /// Used for cleanup after sweep
    weak_tables: std.ArrayListUnmanaged(*TableObject),

    /// Shared metatables for primitive types (string, number, etc.)
    /// These are global state, shared across all threads/coroutines.
    /// Set via debug.setmetatable(), used by metamethod resolution.
    shared_mt: SharedMetatables = .{},

    /// Pre-allocated metamethod key strings (interned, shared across all coroutines)
    /// Initialized via initMetamethodKeys() after GC creation.
    mm_keys: MetamethodKeys = undefined,
    /// True after initMetamethodKeys() has been called
    mm_keys_initialized: bool = false,

    /// GC running state (for stop/restart control)
    /// When false, automatic collection is disabled but manual collect() still works.
    is_running: bool = true,

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .objects = null,
            .strings = std.StringHashMap(*StringObject).init(allocator),
            .bytes_allocated = 0,
            .next_gc = GC_THRESHOLD,
            .root_providers = .{},
            .gc_inhibit = 0,
            .weak_tables = .{},
        };
    }

    /// Get an allocator that tracks allocations for GC threshold calculation.
    /// Use this for data structures that manage their own memory (e.g., HashMap).
    pub fn trackingAllocator(self: *GC) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &tracking_vtable,
        };
    }

    /// Initialize metamethod keys (must be called after GC creation)
    /// This interns all metamethod strings (__add, __sub, etc.)
    pub fn initMetamethodKeys(self: *GC) !void {
        self.mm_keys = try MetamethodKeys.init(self);
        self.mm_keys_initialized = true;
    }

    /// GC INHIBITION API
    ///
    /// Purpose: Temporarily prevent automatic GC collection during sensitive operations
    /// where GC objects exist but are not yet reachable from VM roots.
    ///
    /// Usage: inhibitGC() / allowGC() must always be paired (use defer).
    /// Nesting is supported via counter.
    ///
    /// Use cases:
    /// - materialize.zig: Proto constants being built, not yet attached to Proto
    ///
    /// NOT a substitute for proper root marking - use only when objects
    /// genuinely cannot be rooted yet (e.g., mid-construction).
    pub fn inhibitGC(self: *GC) void {
        self.gc_inhibit += 1;
    }

    /// Re-enable GC after inhibitGC. Decrements the inhibit counter.
    pub fn allowGC(self: *GC) void {
        if (self.gc_inhibit > 0) {
            self.gc_inhibit -= 1;
        }
    }

    /// Stop automatic GC. Returns previous running state.
    /// Manual collect() still works when stopped.
    pub fn stop(self: *GC) bool {
        const was_running = self.is_running;
        self.is_running = false;
        return was_running;
    }

    /// Restart automatic GC.
    pub fn restart(self: *GC) void {
        self.is_running = true;
    }

    /// Perform a GC step. Currently runs a full collection.
    /// Returns true if a collection cycle completed.
    pub fn step(self: *GC) bool {
        if (self.gc_inhibit > 0) return false;
        if (self.root_providers.items.len == 0) return false;
        self.collect();
        return true;
    }

    /// Get memory usage in KB (integer part).
    pub fn getCountKB(self: *GC) usize {
        return self.bytes_allocated / 1024;
    }

    /// Get memory usage remainder in bytes (0-1023).
    pub fn getCountB(self: *GC) usize {
        return self.bytes_allocated % 1024;
    }

    /// Register a root provider for GC marking
    /// Multiple providers can be registered (VM, REPL, test harnesses, etc.)
    pub fn addRootProvider(self: *GC, provider: RootProvider) !void {
        // Debug: check for duplicate registration
        if (builtin.mode == .Debug) {
            for (self.root_providers.items) |p| {
                std.debug.assert(!(p.ptr == provider.ptr and p.vtable == provider.vtable));
            }
        }
        try self.root_providers.append(self.allocator, provider);
    }

    /// Remove a root provider (e.g., when VM is destroyed)
    /// Matches by both ptr and vtable to ensure correct provider removal.
    pub fn removeRootProvider(self: *GC, provider: RootProvider) void {
        var i: usize = 0;
        while (i < self.root_providers.items.len) {
            const p = self.root_providers.items[i];
            if (p.ptr == provider.ptr and p.vtable == provider.vtable) {
                _ = self.root_providers.swapRemove(i);
                return; // Each provider should only be registered once
            }
            i += 1;
        }
    }

    /// Track an external allocation (not managed by GC, but affects threshold).
    /// Use for allocations that are logically part of GC-managed objects
    /// but allocated separately (e.g., VM memory for coroutines).
    pub fn trackAllocation(self: *GC, size: usize) void {
        self.bytes_allocated += size;
    }

    /// Track an external deallocation.
    pub fn trackDeallocation(self: *GC, size: usize) void {
        self.bytes_allocated -= size;
    }

    pub fn deinit(self: *GC) void {
        // Clear intern table first (objects will be freed below)
        self.strings.clearAndFree();

        // Clear weak tables list
        self.weak_tables.deinit(self.allocator);

        // Clear root providers list
        self.root_providers.deinit(self.allocator);

        // Free all remaining objects without mark/sweep
        // (no need to determine liveness at program exit)
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            self.freeObjectFinal(obj);
            current = next;
        }
    }

    // Debug: force GC on every allocation to expose marking bugs
    // Enable temporarily to test GC correctness
    const GC_STRESS_TEST = false;

    /// Allocate a new GC-managed object
    /// T must be a struct with a 'header: GCObject' field as first member
    pub fn allocObject(self: *GC, comptime T: type, extra_bytes: usize) !*T {
        const size = @sizeOf(T) + extra_bytes;

        // Check if GC should run before allocation
        if (GC_STRESS_TEST or self.bytes_allocated + size > self.next_gc) {
            self.tryCollect();
        }

        // Allocate memory
        const memory = try self.allocator.alloc(u8, size);
        const ptr = @as(*T, @ptrCast(@alignCast(memory.ptr)));

        self.bytes_allocated += size;

        return ptr;
    }

    /// Try to run GC if running, not inhibited, and root providers exist
    fn tryCollect(self: *GC) void {
        // Don't run GC if stopped via stop()
        if (!self.is_running) return;
        // Don't run GC if inhibited (during materialization, etc.)
        if (self.gc_inhibit > 0) return;
        // Don't run GC if no root providers registered
        if (self.root_providers.items.len == 0) return;

        self.collect();
    }

    /// Run a full GC cycle: mark all roots via providers, then sweep
    pub fn collect(self: *GC) void {
        // Prepare for new GC cycle
        self.beginCollection();

        // Mark phase: each provider marks its roots
        for (self.root_providers.items) |provider| {
            provider.markRoots(self);
        }

        // Mark shared metatables (global GC state)
        if (self.shared_mt.string) |mt| self.mark(&mt.header);
        if (self.shared_mt.number) |mt| self.mark(&mt.header);
        if (self.shared_mt.boolean) |mt| self.mark(&mt.header);
        if (self.shared_mt.function) |mt| self.mark(&mt.header);
        if (self.shared_mt.nil) |mt| self.mark(&mt.header);

        // Mark metamethod key strings (must survive GC for metamethod dispatch)
        if (self.mm_keys_initialized) {
            for (self.mm_keys.strings) |str| {
                self.mark(&str.header);
            }
        }

        // Finish: ephemeron propagation, weak table cleanup, sweep
        self.finishCollection();
    }

    /// Allocate a new string object
    pub fn allocString(self: *GC, str: []const u8) !*StringObject {
        // Check intern table for existing string
        if (self.strings.get(str)) |existing| {
            return existing;
        }

        // Allocate new StringObject
        const obj = try self.allocObject(StringObject, str.len);

        // Initialize GC header
        obj.header = GCObject.init(.string, self.objects);
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
    pub fn allocTable(self: *GC) !*TableObject {
        const obj = try self.allocObject(TableObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.table, self.objects);
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
    pub fn allocClosure(self: *GC, proto: *ProtoObject) !*ClosureObject {
        const obj = try self.allocObject(ClosureObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.closure, self.objects);
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
        self: *GC,
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
        const obj = try self.allocObject(ProtoObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.proto, self.objects);
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
    pub fn allocUpvalue(self: *GC, location: *TValue) !*UpvalueObject {
        const obj = try self.allocObject(UpvalueObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.upvalue, self.objects);
        obj.location = location;
        obj.closed = TValue.nil;
        obj.next_open = null;

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Allocate a new closed upvalue with a specific value
    /// Used for _ENV in load() and similar cases where the upvalue doesn't reference the stack
    pub fn allocClosedUpvalue(self: *GC, value: TValue) !*UpvalueObject {
        const obj = try self.allocObject(UpvalueObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.upvalue, self.objects);
        obj.closed = value;
        obj.location = &obj.closed; // Point to self (closed state)
        obj.next_open = null;

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Allocate a new native closure object
    pub fn allocNativeClosure(self: *GC, func: NativeFn) !*NativeClosureObject {
        const obj = try self.allocObject(NativeClosureObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.native_closure, self.objects);
        obj.func = func;

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Allocate a new userdata object
    /// data_size: size of the raw data block in bytes
    /// num_user_values: number of user values (0-255)
    pub fn allocUserdata(self: *GC, data_size: usize, num_user_values: u8) !*UserdataObject {
        const extra = @as(usize, num_user_values) * @sizeOf(TValue) + data_size;
        const obj = try self.allocObject(UserdataObject, extra);

        // Initialize GC header
        obj.header = GCObject.init(.userdata, self.objects);
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
        self: *GC,
        vm_ptr: *anyopaque,
        status: ThreadStatus,
        mark_vm: ?*const fn (*anyopaque, *anyopaque) void,
        free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void,
    ) !*ThreadObject {
        const obj = try self.allocObject(ThreadObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.thread, self.objects);
        obj.status = status;
        obj.vm = vm_ptr;
        obj.mark_vm = mark_vm;
        obj.free_vm = free_vm;

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Prepare for a new GC cycle (called before VM marks roots)
    pub fn beginCollection(self: *GC) void {
        // Clear weak tables list from previous cycle
        self.weak_tables.clearRetainingCapacity();
    }

    /// Complete collection: ephemeron propagation, sweep, cleanup (called after marking)
    fn finishCollection(self: *GC) void {
        // Propagate ephemerons until stable
        // For weak-key tables, values are only marked if their keys are marked
        while (self.propagateEphemerons()) {}

        // Clean dead entries from weak tables BEFORE sweep clears marks
        // (sweep clears mark bits, so we need to check them first)
        self.cleanWeakTables();

        // Sweep phase (also runs __gc finalizers)
        self.sweep();

        // Adjust next GC threshold based on survival rate
        self.next_gc = @max(
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.bytes_allocated)) * self.gc_multiplier)),
            self.gc_min_threshold,
        );
    }

    /// Mark all values in a stack slice as reachable
    pub fn markStack(self: *GC, stack: []const TValue) void {
        for (stack) |value| {
            self.markValue(value);
        }
    }

    /// Mark constants array (e.g., from Proto.k)
    pub fn markConstants(self: *GC, constants: []const TValue) void {
        for (constants) |value| {
            self.markValue(value);
        }
    }

    /// Mark a TValue if it contains a GC object
    pub fn markValue(self: *GC, value: TValue) void {
        if (value == .object) {
            markObject(self, value.object);
        }
        // Immediate values (nil, bool, integer, number) don't need marking
    }

    /// Mark a ProtoObject (GC-managed prototype)
    ///
    /// GC SAFETY: This function marks the proto itself, its constants (k),
    /// and nested ProtoObjects. All are now GC-managed.
    pub fn markProtoObject(self: *GC, proto: *ProtoObject) void {
        markObject(self, &proto.header);
    }

    /// Mark an object and recursively mark its children
    fn markObject(self: *GC, obj: *GCObject) void {
        if (obj.marked) return; // Already marked

        obj.marked = true;

        // Mark referenced objects based on type
        switch (obj.type) {
            .string => {
                // Strings have no references to other objects
            },
            .table => {
                const table: *TableObject = @fieldParentPtr("header", obj);
                // Mark metatable if present and parse __mode
                if (table.metatable) |mt| {
                    markObject(self, &mt.header);
                    // Parse __mode from metatable
                    table.weak_mode = self.parseWeakMode(mt);
                } else {
                    table.weak_mode = .none;
                }

                // Handle weak tables differently
                if (table.weak_mode != .none) {
                    // Track weak table for cleanup after sweep
                    self.weak_tables.append(self.allocator, table) catch {
                        // OOM: weak table tracking lost, but GC can continue
                        if (builtin.mode == .Debug) {
                            std.debug.print("GC: failed to track weak table\n", .{});
                        }
                    };

                    // For weak values only: mark all keys but not values
                    if (table.weak_mode == .weak_values) {
                        var iter = table.hash_part.iterator();
                        while (iter.next()) |entry| {
                            // Keys can be any TValue now - mark if object
                            self.markValue(entry.key_ptr.*);
                            // Skip marking values - they are weak
                        }
                    }
                    // For weak keys (ephemerons): defer marking to propagation phase
                    // Keys and values are not marked here - handled by propagateEphemerons
                } else {
                    // Strong table: mark all keys and values
                    var iter = table.hash_part.iterator();
                    while (iter.next()) |entry| {
                        // Mark both key and value (keys can be any TValue)
                        self.markValue(entry.key_ptr.*);
                        self.markValue(entry.value_ptr.*);
                    }
                }
            },
            .closure => {
                const closure: *ClosureObject = @fieldParentPtr("header", obj);
                // Mark upvalues
                for (closure.upvalues) |upval| {
                    markObject(self, &upval.header);
                }
                // Mark proto (GC-managed)
                self.markProtoObject(closure.proto);
            },
            .native_closure => {
                // Native closures have no references to other objects
            },
            .upvalue => {
                // Mark the closed value if the upvalue is closed
                const upval: *UpvalueObject = @fieldParentPtr("header", obj);
                if (upval.isClosed()) {
                    self.markValue(upval.closed);
                }
            },
            .userdata => {
                const ud: *UserdataObject = @fieldParentPtr("header", obj);
                // Mark metatable if present
                if (ud.metatable) |mt| {
                    markObject(self, &mt.header);
                }
                // Mark user values
                for (ud.userValues()) |uv| {
                    self.markValue(uv);
                }
            },
            .proto => {
                const proto: *ProtoObject = @fieldParentPtr("header", obj);
                // Mark constants (may contain GC objects like strings)
                for (proto.k) |value| {
                    self.markValue(value);
                }
                // Mark nested protos
                for (proto.protos) |nested| {
                    markObject(self, &nested.header);
                }
            },
            .thread => {
                // Mark the VM's roots (stack, callframes, upvalues, etc.)
                // Main thread: marked via RootProvider (mark_vm is null)
                // Coroutine threads: marked here via callback
                const thread_obj: *ThreadObject = @fieldParentPtr("header", obj);
                if (thread_obj.mark_vm) |mark_fn| {
                    mark_fn(thread_obj.vm, @ptrCast(self));
                }
            },
        }
    }

    /// Parse __mode string from metatable to determine weak table mode
    fn parseWeakMode(self: *GC, metatable: *TableObject) TableObject.WeakMode {
        const mode_val = metatable.get(TValue.fromString(self.mm_keys.get(.mode))) orelse return .none;
        const mode_str = mode_val.asString() orelse return .none;

        var has_k = false;
        var has_v = false;
        for (mode_str.asSlice()) |c| {
            if (c == 'k' or c == 'K') has_k = true;
            if (c == 'v' or c == 'V') has_v = true;
        }

        if (has_k and has_v) return .weak_both;
        if (has_k) return .weak_keys;
        if (has_v) return .weak_values;
        return .none;
    }

    /// Propagate marks through ephemeron tables (weak keys)
    /// For tables with weak keys, value is only marked if key is marked
    /// Returns true if any new marks were made (requires another iteration)
    fn propagateEphemerons(self: *GC) bool {
        var changed = false;

        for (self.weak_tables.items) |table| {
            // Only process tables with weak keys (ephemerons)
            if (!table.hasWeakKeys()) continue;

            var iter = table.hash_part.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;

                // Check if key is marked (only objects can be unmarked)
                const key_marked = switch (key) {
                    .object => |obj| obj.marked,
                    else => true, // Non-objects (nil, bool, int, number) are always "marked"
                };

                // If key is marked, mark the value (unless weak values)
                if (key_marked and !table.hasWeakValues()) {
                    const value = entry.value_ptr.*;
                    if (value == .object and !value.object.marked) {
                        markObject(self, value.object);
                        changed = true;
                    }
                }
            }
        }

        return changed;
    }

    /// Clean dead entries from weak tables after sweep
    fn cleanWeakTables(self: *GC) void {
        for (self.weak_tables.items) |table| {
            self.cleanWeakTableEntries(table);
            table.weak_mode = .none; // Reset for next cycle
        }
    }

    /// Remove entries from a weak table where key or value was collected
    fn cleanWeakTableEntries(self: *GC, table: *TableObject) void {
        // Collect keys to remove (can't remove during iteration)
        var to_remove: std.ArrayListUnmanaged(TValue) = .{};
        defer to_remove.deinit(self.allocator);

        var iter = table.hash_part.iterator();
        while (iter.next()) |entry| {
            var remove = false;
            const key = entry.key_ptr.*;

            // Check weak key (only objects can be collected)
            if (table.hasWeakKeys()) {
                if (key == .object and !key.object.marked) {
                    remove = true;
                }
            }

            // Check weak value (only for collectable values)
            if (table.hasWeakValues() and !remove) {
                const val = entry.value_ptr.*;
                if (val == .object and !val.object.marked) {
                    remove = true;
                }
            }

            if (remove) {
                to_remove.append(self.allocator, key) catch {};
            }
        }

        // Remove dead entries
        for (to_remove.items) |key| {
            _ = table.hash_part.remove(key);
        }
    }

    /// Sweep phase: free all unmarked objects
    /// Calls __gc finalizers for tables before freeing
    pub fn sweep(self: *GC) void {
        // First pass: call __gc finalizers for unmarked tables
        // We do this before freeing to ensure objects are still valid
        self.runFinalizers();

        // Second pass: free unmarked objects
        var prev: ?*GCObject = null;
        var current = self.objects;

        while (current) |obj| {
            if (obj.marked) {
                // Keep object, clear mark for next cycle
                obj.marked = false;
                prev = obj;
                current = obj.next;
            } else {
                // Free unmarked object
                const next = obj.next;

                if (prev) |p| {
                    p.next = next;
                } else {
                    self.objects = next;
                }

                self.freeObject(obj);
                current = next;
            }
        }
    }

    /// Run __gc finalizers for all unmarked tables that have them
    /// Note: Uses the last registered provider for callValue.
    /// The VM is registered after Runtime, so this picks the active VM.
    /// Multi-VM would need a dedicated finalizer executor.
    fn runFinalizers(self: *GC) void {
        if (self.root_providers.items.len == 0) return;
        // Use last provider (VM) - Runtime is registered first but cannot execute code
        const provider = self.root_providers.items[self.root_providers.items.len - 1];

        // Inhibit GC during finalizer execution to prevent recursive collection
        self.gc_inhibit += 1;
        defer self.gc_inhibit -= 1;

        var current = self.objects;
        while (current) |obj| {
            if (!obj.marked) {
                // Tables and userdata can have __gc finalizers
                const maybe_metatable: ?*TableObject = switch (obj.type) {
                    .table => @as(*TableObject, @fieldParentPtr("header", obj)).metatable,
                    .userdata => @as(*UserdataObject, @fieldParentPtr("header", obj)).metatable,
                    else => null,
                };
                if (maybe_metatable) |mt| {
                    if (mt.get(TValue.fromString(self.mm_keys.get(.gc)))) |gc_fn| {
                        // Call __gc(obj) - errors are ignored (standard Lua behavior)
                        const obj_val: TValue = switch (obj.type) {
                            .table => TValue.fromTable(@fieldParentPtr("header", obj)),
                            .userdata => TValue.fromUserdata(@fieldParentPtr("header", obj)),
                            else => unreachable,
                        };
                        _ = provider.callValue(&gc_fn, &[_]TValue{obj_val}) catch {};
                    }
                }
            }
            current = obj.next;
        }
    }

    /// Free a GC object and update accounting
    fn freeObject(self: *GC, obj: *GCObject) void {
        // For strings, remove from intern table before freeing
        if (obj.type == .string) {
            const str_obj: *StringObject = @fieldParentPtr("header", obj);
            _ = self.strings.remove(str_obj.asSlice());
        }
        self.freeObjectFinal(obj);
    }

    /// Free object without updating intern table (for use during deinit)
    fn freeObjectFinal(self: *GC, obj: *GCObject) void {
        switch (obj.type) {
            .string => {
                const str_obj: *StringObject = @fieldParentPtr("header", obj);
                const size = @sizeOf(StringObject) + str_obj.len;
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(str_obj))[0..size];
                self.allocator.free(memory);
            },
            .table => {
                const table_obj: *TableObject = @fieldParentPtr("header", obj);
                table_obj.deinit(); // Free hash_part
                const size = @sizeOf(TableObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(table_obj))[0..size];
                self.allocator.free(memory);
            },
            .closure => {
                const closure_obj: *ClosureObject = @fieldParentPtr("header", obj);
                // Free upvalues array if allocated
                if (closure_obj.upvalues.len > 0) {
                    self.bytes_allocated -= closure_obj.upvalues.len * @sizeOf(*UpvalueObject);
                    self.allocator.free(closure_obj.upvalues);
                }
                const size = @sizeOf(ClosureObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(closure_obj))[0..size];
                self.allocator.free(memory);
            },
            .native_closure => {
                const native_obj: *NativeClosureObject = @fieldParentPtr("header", obj);
                const size = @sizeOf(NativeClosureObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(native_obj))[0..size];
                self.allocator.free(memory);
            },
            .upvalue => {
                const upval_obj: *UpvalueObject = @fieldParentPtr("header", obj);
                const size = @sizeOf(UpvalueObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(upval_obj))[0..size];
                self.allocator.free(memory);
            },
            .userdata => {
                const ud_obj: *UserdataObject = @fieldParentPtr("header", obj);
                const size = UserdataObject.allocationSize(ud_obj.size, ud_obj.nuvalue);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(ud_obj))[0..size];
                self.allocator.free(memory);
            },
            .proto => {
                const proto_obj: *ProtoObject = @fieldParentPtr("header", obj);
                // Free internal arrays (allocated by materialize)
                if (proto_obj.k.len > 0) {
                    self.bytes_allocated -= proto_obj.k.len * @sizeOf(TValue);
                    self.allocator.free(proto_obj.k);
                }
                if (proto_obj.code.len > 0) {
                    self.bytes_allocated -= proto_obj.code.len * @sizeOf(Instruction);
                    self.allocator.free(proto_obj.code);
                }
                if (proto_obj.protos.len > 0) {
                    self.bytes_allocated -= proto_obj.protos.len * @sizeOf(*ProtoObject);
                    self.allocator.free(proto_obj.protos);
                }
                if (proto_obj.upvalues.len > 0) {
                    self.bytes_allocated -= proto_obj.upvalues.len * @sizeOf(Upvaldesc);
                    self.allocator.free(proto_obj.upvalues);
                }
                if (proto_obj.source.len > 0) {
                    self.bytes_allocated -= proto_obj.source.len;
                    self.allocator.free(proto_obj.source);
                }
                if (proto_obj.lineinfo.len > 0) {
                    self.bytes_allocated -= proto_obj.lineinfo.len * @sizeOf(u32);
                    self.allocator.free(proto_obj.lineinfo);
                }
                // Free the ProtoObject itself
                const size = @sizeOf(ProtoObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(proto_obj))[0..size];
                self.allocator.free(memory);
            },
            .thread => {
                const thread_obj: *ThreadObject = @fieldParentPtr("header", obj);
                // Free VM memory if callback is set (coroutine threads only)
                // Main thread is freed by Runtime.deinit, not here
                if (thread_obj.free_vm) |free_fn| {
                    free_fn(thread_obj.vm, self.allocator);
                }
                const size = @sizeOf(ThreadObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(thread_obj))[0..size];
                self.allocator.free(memory);
            },
        }
    }

    /// Force garbage collection (for debugging/testing)
    /// Runs a full GC cycle: mark all roots via providers, then sweep.
    pub fn forceGC(self: *GC) void {
        self.collect();
    }

    /// Manually mark an object as reachable (for testing / root marking)
    pub fn mark(self: *GC, obj: *GCObject) void {
        markObject(self, obj);
    }

    /// Get current memory usage statistics
    pub fn getStats(self: *GC) struct {
        bytes_allocated: usize,
        next_gc: usize,
        object_count: usize,
    } {
        var object_count: usize = 0;
        var current = self.objects;
        while (current) |obj| {
            object_count += 1;
            current = obj.next;
        }

        return .{
            .bytes_allocated = self.bytes_allocated,
            .next_gc = self.next_gc,
            .object_count = object_count,
        };
    }
};

test "single string mark survives GC" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate a string
    const str = try gc.allocString("hello");

    // Verify it's in the object list
    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_before.object_count);

    // Mark the string
    gc.mark(&str.header);
    try std.testing.expect(str.header.marked);

    // Run GC (sweep phase)
    gc.sweep();

    // String should survive
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_after.object_count);

    // Mark should be cleared for next cycle
    try std.testing.expect(!str.header.marked);

    // Verify string content is intact
    try std.testing.expectEqualStrings("hello", str.asSlice());
}

test "unmarked string is collected" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate a string but don't mark it
    _ = try gc.allocString("garbage");

    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_before.object_count);

    // Run GC without marking
    gc.sweep();

    // String should be collected
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats_after.object_count);
}

test "marked string survives, unmarked is collected" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate two strings
    const survivor = try gc.allocString("keep me");
    const garbage = try gc.allocString("delete me");
    _ = garbage;

    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats_before.object_count);

    // Mark only the survivor
    gc.mark(&survivor.header);

    // Run GC
    gc.sweep();

    // Only survivor should remain
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_after.object_count);

    // Verify survivor content
    try std.testing.expectEqualStrings("keep me", survivor.asSlice());
}

test "markValue marks string in TValue" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate a string through GC
    const str = try gc.allocString("hello from TValue");

    // Wrap it in a TValue
    const value = TValue.fromString(str);

    // Mark through TValue
    gc.markValue(value);

    // Verify the string is marked
    try std.testing.expect(str.header.marked);

    // Run GC - string should survive
    gc.sweep();

    const stats = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.object_count);
    try std.testing.expectEqualStrings("hello from TValue", str.asSlice());
}

test "markStack marks all strings in stack slice" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate strings
    const str1 = try gc.allocString("stack item 1");
    const str2 = try gc.allocString("stack item 2");
    const garbage = try gc.allocString("not on stack");
    _ = garbage;

    // Create a mock stack slice
    var stack: [4]TValue = .{
        TValue.fromString(str1),
        TValue{ .integer = 42 }, // Non-GC value
        TValue.fromString(str2),
        TValue.nil,
    };

    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats_before.object_count);

    // Mark stack
    gc.markStack(&stack);

    // Run GC
    gc.sweep();

    // Only stack items should survive (2 strings)
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats_after.object_count);

    // Verify surviving strings
    try std.testing.expectEqualStrings("stack item 1", str1.asSlice());
    try std.testing.expectEqualStrings("stack item 2", str2.asSlice());
}

test "forceGC collects unmarked objects" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate strings
    _ = try gc.allocString("garbage1");
    _ = try gc.allocString("garbage2");
    const survivor = try gc.allocString("keep");

    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats_before.object_count);

    // Mark only survivor
    gc.mark(&survivor.header);

    // forceGC should collect unmarked objects
    gc.forceGC();

    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_after.object_count);
    try std.testing.expectEqualStrings("keep", survivor.asSlice());
}

test "getStats returns correct memory usage" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const stats_empty = gc.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats_empty.bytes_allocated);
    try std.testing.expectEqual(@as(usize, 0), stats_empty.object_count);

    // Allocate a string
    const str = try gc.allocString("test");
    _ = str;

    const stats_one = gc.getStats();
    try std.testing.expect(stats_one.bytes_allocated > 0);
    try std.testing.expectEqual(@as(usize, 1), stats_one.object_count);

    // Allocate another
    _ = try gc.allocString("test2");

    const stats_two = gc.getStats();
    try std.testing.expect(stats_two.bytes_allocated > stats_one.bytes_allocated);
    try std.testing.expectEqual(@as(usize, 2), stats_two.object_count);
}

test "table marks its contents" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate a table and a string
    const table = try gc.allocTable();
    const str = try gc.allocString("value in table");
    const garbage = try gc.allocString("not referenced");
    _ = garbage;

    // Put string in table
    const key = try gc.allocString("key");
    try table.set(TValue.fromString(key), TValue.fromString(str));

    const stats_before = gc.getStats();
    try std.testing.expectEqual(@as(usize, 4), stats_before.object_count);

    // Mark only the table (should transitively mark key and value strings inside)
    gc.mark(&table.header);

    // Run GC
    gc.sweep();

    // Table, key, and value string should survive, garbage should be collected
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 3), stats_after.object_count);

    // Verify string is still accessible through table
    const retrieved = table.get(TValue.fromString(key));
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("value in table", retrieved.?.asString().?.asSlice());
}

test "markValue marks closure" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    // Allocate a minimal ProtoObject via GC
    const proto = try gc.allocProto(
        &[_]TValue{},
        &[_]Instruction{},
        &[_]*ProtoObject{},
        0,
        false,
        1,
        0,
        &[_]Upvaldesc{},
        "",
        &[_]u32{},
    );

    // Allocate a closure
    const closure = try gc.allocClosure(proto);
    const garbage = try gc.allocString("not referenced");
    _ = garbage;

    const stats_before = gc.getStats();
    // proto + closure + garbage string = 3 objects
    try std.testing.expectEqual(@as(usize, 3), stats_before.object_count);

    // Mark the closure via TValue (should also mark proto transitively)
    gc.markValue(TValue.fromClosure(closure));

    // Run GC
    gc.sweep();

    // Closure and proto should survive, garbage string should be collected
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats_after.object_count);
}
