//! GC Unit Tests
//!
//! Covers basic mark/sweep behaviors for strings and TValue marking.

const std = @import("std");
const gc_mod = @import("gc.zig");
const TValue = @import("../value.zig").TValue;

const GC = gc_mod.GC;

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
