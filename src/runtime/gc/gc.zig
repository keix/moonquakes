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
const Upvaldesc = object.Upvaldesc;
const Instruction = @import("../../compiler/opcodes.zig").Instruction;
const NativeFn = @import("../native.zig").NativeFn;
const TValue = @import("../value.zig").TValue;
const call = @import("../../vm/call.zig");
const MetaEvent = @import("../../vm/metamethod.zig").MetaEvent;

// Initial GC threshold - collection runs when bytes_allocated exceeds this
// After collection, threshold adjusts based on survival rate (gc_multiplier)
const GC_THRESHOLD = 64 * 1024; // 64KB initial threshold

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

    /// Reference to VM for root marking during GC
    /// Uses anyopaque to avoid circular import dependency
    ///
    /// TODO: Refactor to use RootProvider interface for better type safety
    /// Current design (gc.setVM) mirrors Lua's approach and works, but:
    /// - `?*anyopaque` lacks type safety and has unclear responsibility boundaries
    /// Ideal future design:
    /// - GC knows only a `RootProvider` interface (markStack, markGlobals)
    /// - VM implements RootProvider
    /// - GC calls provider.markRoots() without knowing VM internals
    vm: ?*anyopaque,

    // GC tuning parameters
    gc_multiplier: f64 = 2.0, // Heap growth factor
    gc_min_threshold: usize = GC_THRESHOLD,

    /// Counter to inhibit GC during sensitive operations (materialization, etc.)
    /// When > 0, GC will not run automatically
    gc_inhibit: u32 = 0,

    /// List of weak tables found during mark phase
    /// Used for cleanup after sweep
    weak_tables: std.ArrayListUnmanaged(*TableObject),

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .objects = null,
            .strings = std.StringHashMap(*StringObject).init(allocator),
            .bytes_allocated = 0,
            .next_gc = GC_THRESHOLD,
            .vm = null,
            .gc_inhibit = 0,
            .weak_tables = .{},
        };
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

    /// Set VM reference for automatic GC triggering
    pub fn setVM(self: *GC, vm: *anyopaque) void {
        self.vm = vm;
    }

    pub fn deinit(self: *GC) void {
        // Clear intern table first (objects will be freed below)
        self.strings.clearAndFree();

        // Clear weak tables list
        self.weak_tables.deinit(self.allocator);

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

    /// Try to run GC if VM reference is available and not inhibited
    fn tryCollect(self: *GC) void {
        // Don't run GC if inhibited (during materialization, etc.)
        if (self.gc_inhibit > 0) return;
        if (self.vm) |vm_ptr| {
            const VM = @import("../../vm/vm.zig").VM;
            const vm: *VM = @ptrCast(@alignCast(vm_ptr));
            vm.collectGarbage();
        }
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

    /// Check if GC should run (policy decision)
    pub fn shouldCollect(self: *GC, additional_bytes: usize) bool {
        return self.bytes_allocated + additional_bytes > self.next_gc;
    }

    /// Prepare for a new GC cycle (called before VM marks roots)
    pub fn beginCollection(self: *GC) void {
        // Clear weak tables list from previous cycle
        self.weak_tables.clearRetainingCapacity();
    }

    /// Complete collection: ephemeron propagation, sweep, cleanup (called after VM marks roots)
    pub fn collect(self: *GC) void {
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
                    self.weak_tables.append(self.allocator, table) catch {};

                    // For weak values only: mark all keys but not values
                    if (table.weak_mode == .weak_values) {
                        var iter = table.hash_part.iterator();
                        while (iter.next()) |entry| {
                            const key: *StringObject = @constCast(entry.key_ptr.*);
                            markObject(self, &key.header);
                            // Skip marking values - they are weak
                        }
                    }
                    // For weak keys (ephemerons): defer marking to propagation phase
                    // Keys and values are not marked here - handled by propagateEphemerons
                } else {
                    // Strong table: mark all keys and values
                    var iter = table.hash_part.iterator();
                    while (iter.next()) |entry| {
                        const key: *StringObject = @constCast(entry.key_ptr.*);
                        markObject(self, &key.header);
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
        }
    }

    /// Parse __mode string from metatable to determine weak table mode
    fn parseWeakMode(self: *GC, metatable: *TableObject) TableObject.WeakMode {
        const VM = @import("../../vm/vm.zig").VM;
        const vm_ptr = self.vm orelse return .none;
        const vm: *VM = @ptrCast(@alignCast(vm_ptr));

        const mode_val = metatable.get(vm.mm_keys.get(.mode)) orelse return .none;
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
                const key: *StringObject = @constCast(entry.key_ptr.*);

                // If key is marked, mark the value (unless weak values)
                if (key.header.marked and !table.hasWeakValues()) {
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
        var to_remove: std.ArrayListUnmanaged(*const StringObject) = .{};
        defer to_remove.deinit(self.allocator);

        var iter = table.hash_part.iterator();
        while (iter.next()) |entry| {
            var remove = false;
            const key: *StringObject = @constCast(entry.key_ptr.*);

            // Check weak key
            if (table.hasWeakKeys() and !key.header.marked) {
                remove = true;
            }

            // Check weak value (only for collectable values)
            if (table.hasWeakValues() and !remove) {
                const val = entry.value_ptr.*;
                if (val == .object and !val.object.marked) {
                    remove = true;
                }
            }

            if (remove) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
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
    fn runFinalizers(self: *GC) void {
        const VM = @import("../../vm/vm.zig").VM;
        const vm_ptr = self.vm orelse return;
        const vm: *VM = @ptrCast(@alignCast(vm_ptr));

        // Inhibit GC during finalizer execution to prevent recursive collection
        self.gc_inhibit += 1;
        defer self.gc_inhibit -= 1;

        var current = self.objects;
        while (current) |obj| {
            if (!obj.marked and obj.type == .table) {
                const table: *TableObject = @fieldParentPtr("header", obj);
                if (table.metatable) |mt| {
                    // Look up __gc in metatable
                    if (mt.get(vm.mm_keys.get(.gc))) |gc_fn| {
                        // Call __gc(table)
                        // Errors in finalizers are ignored (standard Lua behavior)
                        _ = call.callValue(vm, gc_fn, &[_]TValue{TValue.fromTable(table)}) catch {};
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
        }
    }

    /// Force garbage collection (for debugging/testing)
    /// Note: Only runs sweep phase. Mark roots manually before calling.
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

// =============================================================================
// Tests
// =============================================================================

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
    try table.set(key, TValue.fromString(str));

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
    const retrieved = table.get(key);
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
