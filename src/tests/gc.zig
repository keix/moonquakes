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
    try gc.tableSet(table, TValue.fromString(try gc.allocString("k")), TValue.fromString(child));

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expectEqual(@as(usize, 3), gc.getStats().object_count);
    try std.testing.expectEqualStrings("survivor", child.asSlice());
}

test "closed upvalue write barrier keeps white child reachable from black upvalue" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var slot: TValue = .nil;
    const upvalue = try gc.allocUpvalue(&slot, null);
    upvalue.close();

    var roots = TestRoots{
        .values = &[_]TValue{TValue{ .object = &upvalue.header }},
    };
    try gc.addRootProvider(roots.provider());

    gc.beginCollection();
    gc.markCycleRoots();
    try std.testing.expect(gc.propagateOne());
    try std.testing.expect(gc.isBlack(&upvalue.header));

    const child = try gc.allocString("captured");
    gc.upvalueSet(upvalue, TValue.fromString(child));

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expectEqualStrings("captured", upvalue.get().asString().?.asSlice());
    try std.testing.expectEqual(@as(usize, 2), gc.getStats().object_count);
}

test "userdata metatable barrier keeps white metatable reachable from black userdata" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const ud = try gc.allocUserdata(0, 0);
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromUserdata(ud)},
    };
    try gc.addRootProvider(roots.provider());

    gc.beginCollection();
    gc.markCycleRoots();
    try std.testing.expect(gc.propagateOne());
    try std.testing.expect(gc.isBlack(&ud.header));

    const mt = try gc.allocTable();
    gc.userdataSetMetatable(ud, mt);

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expect(ud.metatable == mt);
    try std.testing.expectEqual(@as(usize, 2), gc.getStats().object_count);
}

test "file reference barriers keep white children reachable from black file object" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const file_obj = try gc.allocStdioFile(.stdout);
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromFile(file_obj)},
    };
    try gc.addRootProvider(roots.provider());

    gc.beginCollection();
    gc.markCycleRoots();
    try std.testing.expect(gc.propagateOne());
    try std.testing.expect(gc.isBlack(&file_obj.header));

    const mt = try gc.allocTable();
    const mode = try gc.allocString("w");
    gc.fileSetMetatable(file_obj, mt);
    gc.fileSetStringRef(file_obj, &file_obj.mode, mode);

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expect(file_obj.metatable == mt);
    try std.testing.expectEqualStrings("w", file_obj.mode.?.asSlice());
    try std.testing.expectEqual(@as(usize, 3), gc.getStats().object_count);
}

test "weak value table does not retain white value" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try gc.initMetamethodKeys();

    const weak_table = try gc.allocTable();
    const metatable = try gc.allocTable();
    const mode_str = try gc.allocString("v");
    try gc.tableSet(metatable, TValue.fromString(gc.mm_keys.get(.mode)), TValue.fromString(mode_str));
    gc.tableSetMetatable(weak_table, metatable);

    const key = try gc.allocString("k");
    const value = try gc.allocTable();
    try gc.tableSet(weak_table, TValue.fromString(key), TValue.fromTable(value));

    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(weak_table)},
    };
    try gc.addRootProvider(roots.provider());

    const before = gc.getStats().object_count;
    gc.collect();

    try std.testing.expect(before > gc.getStats().object_count);
    try std.testing.expectEqual(@as(?TValue, null), weak_table.get(TValue.fromString(key)));
}

test "finalizer queue keeps unreachable object alive until drained" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try gc.initMetamethodKeys();

    const mt = try gc.allocTable();
    const gc_fn = try gc.allocNativeClosure(.{ .id = .print });
    try gc.tableSet(mt, TValue.fromString(gc.mm_keys.get(.gc)), TValue.fromNativeClosure(gc_fn));

    const obj = try gc.allocTable();
    gc.tableSetMetatable(obj, mt);

    gc.collect();
    const after_first = gc.getStats().object_count;
    try std.testing.expect(gc.hasPendingFinalizers());
    try std.testing.expect(after_first >= 3);

    gc.collect();
    try std.testing.expect(gc.hasPendingFinalizers());
    try std.testing.expectEqual(after_first, gc.getStats().object_count);
}

test "thread entry function barrier keeps white callable alive from black thread" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    var dummy_vm: u8 = 0;
    const thread = try gc.allocThread(@ptrCast(&dummy_vm), .suspended, null, null);
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromThread(thread)},
    };
    try gc.addRootProvider(roots.provider());

    gc.beginCollection();
    gc.markCycleRoots();
    try std.testing.expect(gc.propagateOne());
    try std.testing.expect(gc.isBlack(&thread.header));

    const entry = try gc.allocNativeClosure(.{ .id = .print });
    gc.threadSetEntryFunc(thread, &entry.header);

    gc.finishMarkPhase();
    gc.sweep();
    gc.finishSweepCycle();

    try std.testing.expect(thread.entry_func == &entry.header);
    try std.testing.expectEqual(@as(usize, 2), gc.getStats().object_count);
}

test "generational step ages survivor from young to survival to old" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    gc.mode = .generational;

    const survivor = try gc.allocString("age-me");
    try std.testing.expectEqual(object.ObjectGeneration.young, survivor.header.generation);

    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromString(survivor)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.survival, survivor.header.generation);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, survivor.header.generation);
}

test "generational mode schedules a major cycle after minor interval" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    gc.mode = .generational;
    gc.generational_major_interval = 1;

    const survivor = try gc.allocString("major");
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromString(survivor)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(@as(u8, 1), gc.generational_minor_cycles);
    try std.testing.expectEqual(object.ObjectGeneration.survival, survivor.header.generation);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(@as(u8, 0), gc.generational_minor_cycles);
    try std.testing.expectEqual(object.ObjectGeneration.old, survivor.header.generation);
}

test "generational minor clears weak value entries for unreachable young values" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try gc.initMetamethodKeys();
    gc.mode = .generational;
    gc.generational_major_interval = 8;

    const weak_table = try gc.allocTable();
    const metatable = try gc.allocTable();
    const mode_str = try gc.allocString("v");
    try gc.tableSet(metatable, TValue.fromString(gc.mm_keys.get(.mode)), TValue.fromString(mode_str));
    gc.tableSetMetatable(weak_table, metatable);

    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(weak_table)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, weak_table.header.generation);

    const key = try gc.allocString("k");
    const value = try gc.allocTable();
    try gc.tableSet(weak_table, TValue.fromString(key), TValue.fromTable(value));
    try std.testing.expectEqual(object.ObjectGeneration.young, value.header.generation);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(@as(?TValue, null), weak_table.get(TValue.fromString(key)));
}

test "generational minor enqueues finalizer for unreachable young object" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try gc.initMetamethodKeys();
    gc.mode = .generational;
    gc.generational_major_interval = 8;

    const holder = try gc.allocTable();
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(holder)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, holder.header.generation);

    const mt = try gc.allocTable();
    const gc_fn = try gc.allocNativeClosure(.{ .id = .print });
    try gc.tableSet(mt, TValue.fromString(gc.mm_keys.get(.gc)), TValue.fromNativeClosure(gc_fn));

    const obj = try gc.allocTable();
    gc.tableSetMetatable(obj, mt);
    try gc.tableSet(holder, .{ .integer = 1 }, TValue.fromTable(obj));
    try gc.tableSet(holder, .{ .integer = 1 }, .nil);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.hasPendingFinalizers());

    const queued = gc.finalizer_queue.items[0];
    try std.testing.expect(queued.obj == &obj.header);
    try std.testing.expectEqual(TValue.fromNativeClosure(gc_fn), queued.func);
}

test "generational minor does not enqueue finalizer for unreachable old object" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    try gc.initMetamethodKeys();
    gc.mode = .generational;
    gc.generational_major_interval = 8;

    const mt = try gc.allocTable();
    const gc_fn = try gc.allocNativeClosure(.{ .id = .print });
    try gc.tableSet(mt, TValue.fromString(gc.mm_keys.get(.gc)), TValue.fromNativeClosure(gc_fn));

    const obj = try gc.allocTable();
    gc.tableSetMetatable(obj, mt);

    var root_slot = [_]TValue{TValue.fromTable(obj)};
    var roots = TestRoots{
        .values = root_slot[0..],
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, obj.header.generation);

    root_slot[0] = .nil;

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(!gc.hasPendingFinalizers());

    gc.collect();
    try std.testing.expect(gc.hasPendingFinalizers());
    try std.testing.expectEqual(@as(usize, 1), gc.finalizer_queue.items.len);
    try std.testing.expect(gc.finalizer_queue.items[0].obj == &obj.header);
}

test "generational minor keeps young child reachable from remembered old parent" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    gc.mode = .generational;
    gc.generational_major_interval = 8;

    const parent = try gc.allocTable();
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(parent)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.survival, parent.header.generation);
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, parent.header.generation);

    const key = try gc.allocString("k");
    const child = try gc.allocString("young");
    try gc.tableSet(parent, TValue.fromString(key), TValue.fromString(child));

    try std.testing.expectEqual(@as(usize, 1), gc.remembered_set.items.len);
    try std.testing.expect(gc.stepSized(0));

    try std.testing.expectEqualStrings("young", parent.get(TValue.fromString(key)).?.asString().?.asSlice());
    try std.testing.expect(gc.getStats().object_count >= 3);
}

test "remembered set prunes old table after child ages out of young generation" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    gc.mode = .generational;
    gc.generational_major_interval = 8;

    const parent = try gc.allocTable();
    var roots = TestRoots{
        .values = &[_]TValue{TValue.fromTable(parent)},
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, parent.header.generation);

    const key = try gc.allocString("k");
    const child = try gc.allocString("age-out");
    try gc.tableSet(parent, TValue.fromString(key), TValue.fromString(child));
    try std.testing.expectEqual(@as(usize, 1), gc.remembered_set.items.len);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.survival, child.header.generation);
    try std.testing.expectEqual(@as(usize, 1), gc.remembered_set.items.len);

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, child.header.generation);
    try std.testing.expectEqual(@as(usize, 0), gc.remembered_set.items.len);
    try std.testing.expect(!parent.header.remembered);
}

test "generational minor does not collect unreachable old object until major cycle" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    gc.mode = .generational;
    gc.generational_major_interval = 1;

    const survivor = try gc.allocString("old");
    var root_slot = [_]TValue{TValue.fromString(survivor)};
    var roots = TestRoots{
        .values = root_slot[0..],
    };
    try gc.addRootProvider(roots.provider());

    try std.testing.expect(gc.stepSized(0));
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(object.ObjectGeneration.old, survivor.header.generation);

    root_slot[0] = .nil;

    const before_minor = gc.getStats().object_count;
    try std.testing.expect(gc.stepSized(0));
    try std.testing.expectEqual(before_minor, gc.getStats().object_count);

    gc.collect();
    try std.testing.expectEqual(@as(usize, 0), gc.getStats().object_count);
}
