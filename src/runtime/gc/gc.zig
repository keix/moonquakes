const std = @import("std");
const builtin = @import("builtin");
const object = @import("object.zig");
const GCObject = object.GCObject;
const GCObjectType = object.GCObjectType;
const StringObject = object.StringObject;

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

    // GC tuning parameters
    gc_multiplier: f64 = 2.0, // Heap growth factor
    gc_min_threshold: usize = 1024, // Minimum bytes before first GC

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .objects = null,
            .bytes_allocated = 0,
            .next_gc = 1024, // gc_min_threshold
        };
    }

    pub fn deinit(self: *GC) void {
        // Final cleanup - collect all remaining objects
        self.collectGarbage();

        // Free any remaining objects (should be none after collection)
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
            // TODO: Need VM reference for root marking
            // self.collectGarbage(vm);
        }

        // Allocate memory
        const memory = try self.allocator.alloc(u8, size);
        const ptr = @as(*T, @ptrCast(@alignCast(memory.ptr)));

        self.bytes_allocated += size;

        return ptr;
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

    /// Mark phase: traverse and mark all reachable objects
    fn markRoots(_: *GC, vm: anytype) void {
        _ = vm; // TODO: Implement when VM integration is ready

        // TODO: Mark VM stack
        // for (vm.stack[vm.base..vm.top]) |value| {
        //     self.markValue(value);
        // }

        // TODO: Mark global environment
        // if (vm.globals) |globals| {
        //     self.markObject(&globals.header);
        // }

        // TODO: Mark constants in current function
        // if (vm.current_proto) |proto| {
        //     for (proto.k) |constant| {
        //         self.markValue(constant);
        //     }
        // }

        // TODO: Mark call stack
        // for (vm.call_stack[0..vm.call_depth]) |frame| {
        //     if (frame.proto) |proto| {
        //         for (proto.k) |constant| {
        //             self.markValue(constant);
        //         }
        //     }
        // }
    }

    /// Mark a TValue if it contains a GC object
    fn markValue(self: *GC, value: anytype) void {
        _ = self;
        _ = value;

        // TODO: Implement based on TValue structure
        // switch (value) {
        //     .string => |str_obj| self.markObject(&str_obj.header),
        //     .table => |table_obj| self.markObject(&table_obj.header),
        //     .function => |func_obj| self.markObject(&func_obj.header),
        //     else => {}, // Immediate values don't need marking
        // }
    }

    /// Mark an object and recursively mark its children
    fn markObject(_: *GC, obj: *GCObject) void {
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
            .function => {
                // TODO: Mark function upvalues when implemented
                // const func = @fieldParentPtr(FunctionObject, "header", obj);
                // self.markFunction(func);
            },
            .userdata => {
                // Basic userdata has no references
            },
        }
    }

    /// Sweep phase: free all unmarked objects
    fn sweep(self: *GC) void {
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
                // TODO: Implement when TableObject is available
                // const table_obj = @fieldParentPtr(TableObject, "header", obj);
                // // Free table data structures
                // self.allocator.destroy(table_obj);
            },
            .function => {
                // TODO: Implement when FunctionObject is available
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
