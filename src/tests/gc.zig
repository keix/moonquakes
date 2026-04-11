const std = @import("std");
const gc_mod = @import("../runtime/gc/gc.zig");
const object = @import("../runtime/gc/object.zig");
const TValue = @import("../runtime/value.zig").TValue;

const GC = gc_mod.GC;
const RootProvider = gc_mod.RootProvider;

const TestRoots = struct {
    values: []const TValue,

    const vtable = RootProvider.VTable{
        .markRoots = markRoots,
    };

    fn provider(self: *TestRoots) RootProvider {
        return RootProvider.init(TestRoots, self, &vtable);
    }

    fn markRoots(ctx: *anyopaque, gc: *GC) void {
        const self: *TestRoots = @ptrCast(@alignCast(ctx));
        for (self.values) |value| {
            gc.markValue(value);
        }
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

    // Prepare for collection (flip mark, so fresh objects are white)
    gc.beginCollection();

    // Mark the string
    gc.mark(&str.header);
    try std.testing.expect(gc.isMarked(&str.header));

    // Run GC (sweep phase)
    gc.sweep();
    gc.gc_state = .idle;

    // String should survive
    const stats_after = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats_after.object_count);

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

    // Prepare for collection (flip mark, so objects become white)
    gc.beginCollection();

    // Run GC without marking anything
    gc.sweep();
    gc.gc_state = .idle;

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

    // Prepare for collection
    gc.beginCollection();

    // Mark only the survivor
    gc.mark(&survivor.header);

    // Run GC
    gc.sweep();
    gc.gc_state = .idle;

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

    // Prepare for collection
    gc.beginCollection();

    // Mark through TValue
    gc.markValue(value);

    // Verify the string is marked
    try std.testing.expect(gc.isMarked(&str.header));

    // Run GC - string should survive
    gc.sweep();
    gc.gc_state = .idle;

    const stats = gc.getStats();
    try std.testing.expectEqual(@as(usize, 1), stats.object_count);
    try std.testing.expectEqualStrings("hello from TValue", str.asSlice());
}

test "table internal allocations are tracked by GC accounting" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const table = try gc.allocTable();
    const before = gc.getStats().bytes_allocated;

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try table.set(.{ .integer = @intCast(i + 1) }, .{ .integer = @intCast(i + 10) });
    }

    const after_insert = gc.getStats().bytes_allocated;
    try std.testing.expect(after_insert > before);
    gc.beginCollection();
    gc.sweep();
    gc.gc_state = .idle;

    try std.testing.expectEqual(@as(usize, 0), gc.getStats().object_count);
}

test "gc stepSized progresses a collection cycle incrementally" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const survivor = try gc.allocString("keep");
    _ = try gc.allocString("collect-1");
    _ = try gc.allocString("collect-2");

    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromString(survivor)},
    };
    try gc.addRootProvider(roots.provider());

    var steps: usize = 0;
    var completed = false;
    while (!completed and steps < 16) : (steps += 1) {
        completed = gc.stepSized(1);
        if (!completed) {
            try std.testing.expect(gc.gc_state != .idle);
        }
    }

    try std.testing.expect(completed);
    try std.testing.expect(steps > 0);
    try std.testing.expectEqual(gc_mod.GCState.idle, gc.gc_state);
    try std.testing.expectEqual(@as(usize, 1), gc.getStats().object_count);
    try std.testing.expectEqualStrings("keep", survivor.asSlice());
}

test "gc stepSized with large budget completes the cycle immediately" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const survivor = try gc.allocString("keep");
    _ = try gc.allocString("collect-now");

    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromString(survivor)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(20000));
    try std.testing.expectEqual(gc_mod.GCState.idle, gc.gc_state);
    try std.testing.expectEqual(@as(usize, 1), gc.getStats().object_count);
    try std.testing.expectEqualStrings("keep", survivor.asSlice());
}

test "table write barrier keeps white child reachable from black table" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const table = try gc.allocTable();
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(table)},
    };
    try gc.addRootProvider(roots.provider());

    gc.beginCollection();
    gc.markCycleRoots();
    try std.testing.expect(gc.propagateOne());
    try std.testing.expect(gc.isBlack(&table.header));

    const child = try gc.allocString("survivor");
    try object.tableSetWithBarrier(&gc, table, TValue.fromString(try gc.allocString("k")), TValue.fromString(child));

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expectEqual(@as(usize, 3), gc.getStats().object_count);
    try std.testing.expectEqualStrings("survivor", child.asSlice());
}
