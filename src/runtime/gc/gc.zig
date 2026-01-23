const std = @import("std");
const builtin = @import("builtin");
const object = @import("object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const Proto = @import("../../compiler/proto.zig").Proto;
const TValue = @import("../value.zig").TValue;

/// Moonquakes Mark & Sweep Garbage Collector
///
/// This is a simple, non-incremental mark-and-sweep collector.
/// It replaces the arena allocator for automatic memory management.
pub const GC = struct {
    /// System allocator for actual memory allocation
    allocator: std.mem.Allocator,

    /// Linked list of all GC-managed objects
    objects: ?*GCObject,

    /// Total bytes currently allocated
    bytes_allocated: usize,

    /// Threshold for triggering next collection
    next_gc: usize,

    /// Reference to VM for root marking during GC
    /// Uses anyopaque to avoid circular import dependency
    vm: ?*anyopaque,

    // GC tuning parameters
    gc_multiplier: f64 = 2.0, // Heap growth factor
    gc_min_threshold: usize = 1024, // Minimum bytes before first GC

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .objects = null,
            .bytes_allocated = 0,
            .next_gc = 2048, // gc_min_threshold
            .vm = null,
        };
    }

    /// Set VM reference for automatic GC triggering
    pub fn setVM(self: *GC, vm: *anyopaque) void {
        self.vm = vm;
    }

    pub fn deinit(self: *GC) void {
        // Free all remaining objects without mark/sweep
        // (no need to determine liveness at program exit)
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            self.freeObject(obj);
            current = next;
        }
    }

    /// Allocate a new GC-managed object
    /// T must be a struct with a 'header: GCObject' field as first member
    pub fn allocObject(self: *GC, comptime T: type, extra_bytes: usize) !*T {
        const size = @sizeOf(T) + extra_bytes;

        // Check if GC should run before allocation
        if (self.bytes_allocated + size > self.next_gc) {
            self.tryCollect();
        }

        // Allocate memory
        const memory = try self.allocator.alloc(u8, size);
        const ptr = @as(*T, @ptrCast(@alignCast(memory.ptr)));

        self.bytes_allocated += size;

        return ptr;
    }

    /// Try to run GC if VM reference is available
    fn tryCollect(self: *GC) void {
        // _ = self;
        // TODO: Uncomment to enable automatic GC
        if (self.vm) |vm_ptr| {
            const VM = @import("../../vm/vm.zig").VM;
            const vm: *VM = @ptrCast(@alignCast(vm_ptr));
            vm.collectGarbage();
        }
    }

    /// Allocate a new string object
    pub fn allocString(self: *GC, str: []const u8) !*StringObject {
        const obj = try self.allocObject(StringObject, str.len);

        // Initialize GC header
        obj.header = GCObject.init(.string, self.objects);
        obj.len = str.len;
        obj.hash = StringObject.hashString(str);

        // Copy string data inline
        @memcpy(obj.data()[0..str.len], str);

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Allocate a new table object
    pub fn allocTable(self: *GC) !*TableObject {
        const obj = try self.allocObject(TableObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.table, self.objects);
        obj.hash_part = TableObject.HashMap.init(self.allocator);
        obj.allocator = self.allocator;

        // Add to GC object list
        self.objects = &obj.header;

        return obj;
    }

    /// Allocate a new closure object
    pub fn allocClosure(self: *GC, proto: *const Proto) !*ClosureObject {
        const obj = try self.allocObject(ClosureObject, 0);

        // Initialize GC header
        obj.header = GCObject.init(.closure, self.objects);
        obj.proto = proto;

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

    /// Main garbage collection entry point
    pub fn collectGarbage(self: *GC) void {
        const before = self.bytes_allocated;

        // TODO: Mark phase - need VM reference
        // self.markRoots(vm);

        // Sweep phase
        self.sweep();

        const after = self.bytes_allocated;

        // Adjust next GC threshold based on survival rate
        self.next_gc = @max(@as(usize, @intFromFloat(@as(f64, @floatFromInt(after)) * self.gc_multiplier)), self.gc_min_threshold);

        // GC stats output (disabled in ReleaseFast for performance)
        if (builtin.mode != .ReleaseFast) {
            std.log.info("GC: {} -> {} bytes, next at {}", .{ before, after, self.next_gc });
        }
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
        switch (value) {
            .string => |str_obj| {
                // Cast away const to mark the header
                const mutable_str: *StringObject = @constCast(str_obj);
                markObject(self, &mutable_str.header);
            },
            // TODO: Mark tables when they become GC-managed
            // .table => |table_obj| markObject(self, &table_obj.header),
            else => {}, // Immediate values (nil, bool, number, etc.) don't need marking
        }
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
                // TODO: Mark table contents when tables are implemented
                // const table = @fieldParentPtr(TableObject, "header", obj);
                // self.markTable(table);
            },
            .closure => {
                // TODO: Mark function upvalues when implemented
                // const func = @fieldParentPtr(FunctionObject, "header", obj);
                // self.markFunction(func);
            },
            .upvalue => {
                // Mark the closed value if the upvalue is closed
                const upval: *UpvalueObject = @fieldParentPtr("header", obj);
                if (upval.isClosed()) {
                    self.markValue(upval.closed);
                }
            },
            .userdata => {
                // Basic userdata has no references
            },
        }
    }

    /// Sweep phase: free all unmarked objects
    pub fn sweep(self: *GC) void {
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

    /// Free a GC object and update accounting
    fn freeObject(self: *GC, obj: *GCObject) void {
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
                const size = @sizeOf(ClosureObject);
                self.bytes_allocated -= size;
                const memory = @as([*]u8, @ptrCast(closure_obj))[0..size];
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
                // TODO: Implement when userdata is available
            },
        }
    }

    /// Force garbage collection (for debugging/testing)
    pub fn forceGC(self: *GC) void {
        self.collectGarbage();
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
    const value = TValue{ .string = str };

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
        TValue{ .string = str1 },
        TValue{ .integer = 42 }, // Non-GC value
        TValue{ .string = str2 },
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
