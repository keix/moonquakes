//! GC Weak Table Support
//!
//! Responsibilities:
//!   - Parse __mode for weak table semantics
//!   - Ephemeron propagation (weak keys)
//!   - Cleanup of dead entries after sweep

const std = @import("std");
const object = @import("object.zig");
const TableObject = object.TableObject;
const TValue = @import("../value.zig").TValue;

/// Parse __mode string from metatable to determine weak table mode
pub fn parseWeakMode(self: anytype, metatable: *TableObject) TableObject.WeakMode {
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
pub fn propagateEphemerons(self: anytype) bool {
    var changed = false;

    for (self.weak_tables.items) |table| {
        // Only process tables with weak keys (ephemerons)
        if (!table.hasWeakKeys()) continue;

        var iter = table.hash_part.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;

            // Check if key is marked (only objects can be unmarked)
            const key_marked = switch (key) {
                .object => |o| self.isMarked(o),
                else => true, // Non-objects (nil, bool, int, number) are always "marked"
            };

            // If key is marked, mark the value (unless weak values)
            if (key_marked and !table.hasWeakValues()) {
                const value = entry.value_ptr.*;
                if (value == .object and self.isWhite(value.object)) {
                    self.markGray(value.object);
                    changed = true;
                }
            }
        }
    }

    return changed;
}

/// Clean dead entries from weak tables after sweep
pub fn cleanWeakTables(self: anytype) void {
    for (self.weak_tables.items) |table| {
        cleanWeakTableEntries(self, table);
        table.weak_mode = .none; // Reset for next cycle
    }
}

/// Remove entries from a weak table where key or value was collected
fn cleanWeakTableEntries(self: anytype, table: *TableObject) void {
    // Collect keys to remove (can't remove during iteration)
    var to_remove: std.ArrayListUnmanaged(TValue) = .{};
    defer to_remove.deinit(self.allocator);

    var iter = table.hash_part.iterator();
    while (iter.next()) |entry| {
        var remove = false;
        const key = entry.key_ptr.*;

        // Check weak key (only objects can be collected)
        if (table.hasWeakKeys()) {
            if (key == .object and self.isWhite(key.object)) {
                remove = true;
            }
        }

        // Check weak value (only for collectable values)
        if (table.hasWeakValues() and !remove) {
            const val = entry.value_ptr.*;
            if (val == .object and self.isWhite(val.object)) {
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
