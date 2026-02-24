//! GC Finalizer Queue
//!
//! Responsibilities:
//!   - Discover __gc finalizers for unreachable objects
//!   - Queue finalizers for deferred execution
//!   - Keep queued objects and closures alive until drain

const object = @import("object.zig");
const TableObject = object.TableObject;
const UserdataObject = object.UserdataObject;
const TValue = @import("../value.zig").TValue;

/// Mark pending finalizers as roots to keep them alive across cycles.
pub fn markFinalizerQueue(self: anytype) void {
    for (self.finalizer_queue.items) |item| {
        self.markGray(item.obj);
        self.markGrayValue(item.func);
    }
}

/// Enqueue __gc finalizers for newly unreachable objects.
/// The objects and their finalizer functions are marked to keep them alive
/// until execution.
pub fn enqueueFinalizers(self: anytype) void {
    if (!self.mm_keys_initialized) return;
    var current = self.objects;
    while (current) |obj| {
        if (self.isWhite(obj) and !obj.finalizer_queued) {
            const maybe_metatable: ?*TableObject = switch (obj.type) {
                .table => @as(*TableObject, @fieldParentPtr("header", obj)).metatable,
                .userdata => @as(*UserdataObject, @fieldParentPtr("header", obj)).metatable,
                else => null,
            };
            if (maybe_metatable) |mt| {
                if (mt.get(TValue.fromString(self.mm_keys.get(.gc)))) |gc_fn| {
                    if (self.finalizer_queue.append(self.allocator, .{
                        .func = gc_fn,
                        .obj = obj,
                    })) |_| {
                        obj.finalizer_queued = true;

                        // Keep object and finalizer function alive.
                        self.markGray(obj);
                        self.markGrayValue(gc_fn);
                    } else |_| {}
                }
            }
        }
        current = obj.next;
    }
}
