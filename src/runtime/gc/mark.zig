//! GC Marking & Barrier
//!
//! Responsibilities:
//!   - Mark/gray/black classification helpers
//!   - Mark phase traversal (scanChildren/propagate)
//!   - Write barrier for incremental invariants

const object = @import("object.zig");
const GCObject = object.GCObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const ProtoObject = object.ProtoObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;
const TValue = @import("../value.zig").TValue;

pub fn isMarked(self: anytype, obj: *const GCObject) bool {
    return obj.mark_bit == self.current_mark;
}

pub fn isWhite(self: anytype, obj: *const GCObject) bool {
    return obj.mark_bit != self.current_mark;
}

pub fn isGray(self: anytype, obj: *const GCObject) bool {
    return isMarked(self, obj) and obj.in_gray;
}

pub fn isBlack(self: anytype, obj: *const GCObject) bool {
    return isMarked(self, obj) and !obj.in_gray;
}

/// Flip the mark bit for next cycle
/// This avoids O(n) sweep reset - all objects become white implicitly
pub fn flipMark(self: anytype) void {
    self.current_mark = !self.current_mark;
}

/// Mark object as gray (reachable, children not yet scanned)
/// Non-recursive: adds to gray list for later processing
/// Note: This is for first-time marking. Re-graying black objects
/// during incremental marking must use barrierBack().
pub fn markGray(self: anytype, obj: *GCObject) void {
    // Skip if already marked
    if (isMarked(self, obj)) return;

    // Mark object (white → gray)
    obj.mark_bit = self.current_mark;
    obj.in_gray = true;

    // Add to gray list (LIFO for cache locality)
    obj.gray_next = self.gray_list;
    self.gray_list = obj;
}

/// Mark a TValue as gray if it contains a GC object
pub fn markGrayValue(self: anytype, value: TValue) void {
    if (value == .object) {
        markGray(self, value.object);
    }
}

/// Check if gray list is empty
pub fn grayListEmpty(self: anytype) bool {
    return self.gray_list == null;
}

/// Pop an object from the gray list for processing
fn popGray(self: anytype) ?*GCObject {
    const obj = self.gray_list orelse return null;
    self.gray_list = obj.gray_next;
    obj.gray_next = null;
    obj.in_gray = false; // Gray → Black
    return obj;
}

/// Process one object from the gray list
/// Marks children as gray (non-recursive)
/// Returns true if an object was processed, false if gray list empty
pub fn propagateOne(self: anytype) bool {
    const obj = popGray(self) orelse return false;
    scanChildren(self, obj);
    return true;
}

/// Scan children of a black object, marking them gray
/// This is the non-recursive version of the child-marking in markObject
fn scanChildren(self: anytype, obj: *GCObject) void {
    switch (obj.type) {
        .string => {
            // Strings have no references
        },
        .table => {
            const table: *TableObject = @fieldParentPtr("header", obj);
            // Mark metatable and parse __mode
            if (table.metatable) |mt| {
                markGray(self, &mt.header);
                table.weak_mode = self.parseWeakMode(mt);
            } else {
                table.weak_mode = .none;
            }

            // Handle weak tables differently
            if (table.weak_mode != .none) {
                // Track for cleanup
                self.weak_tables.append(self.allocator, table) catch {};

                // For weak values: mark keys only
                if (table.weak_mode == .weak_values) {
                    var iter = table.hash_part.iterator();
                    while (iter.next()) |entry| {
                        markGrayValue(self, entry.key_ptr.*);
                    }
                }
                // weak_keys (ephemerons): defer to propagateEphemerons
            } else {
                // Strong table: mark all keys and values
                var iter = table.hash_part.iterator();
                while (iter.next()) |entry| {
                    markGrayValue(self, entry.key_ptr.*);
                    markGrayValue(self, entry.value_ptr.*);
                }
            }
        },
        .closure => {
            const closure: *ClosureObject = @fieldParentPtr("header", obj);
            for (closure.upvalues) |upval| {
                markGray(self, &upval.header);
            }
            markGray(self, &closure.proto.header);
        },
        .native_closure => {
            // No references
        },
        .upvalue => {
            const upval: *UpvalueObject = @fieldParentPtr("header", obj);
            if (upval.isClosed()) {
                markGrayValue(self, upval.closed);
            }
        },
        .userdata => {
            const ud: *UserdataObject = @fieldParentPtr("header", obj);
            if (ud.metatable) |mt| {
                markGray(self, &mt.header);
            }
            for (ud.userValues()) |uv| {
                markGrayValue(self, uv);
            }
        },
        .proto => {
            const proto: *ProtoObject = @fieldParentPtr("header", obj);
            for (proto.k) |value| {
                markGrayValue(self, value);
            }
            for (proto.protos) |nested| {
                markGray(self, &nested.header);
            }
        },
        .thread => {
            const thread_obj: *ThreadObject = @fieldParentPtr("header", obj);
            if (thread_obj.entry_func) |entry_fn| {
                markGray(self, entry_fn);
            }
            if (thread_obj.mark_vm) |mark_fn| {
                mark_fn(thread_obj.vm, @ptrCast(self));
            }
        },
    }
}

/// Propagate all gray objects until the list is empty
/// This is used for STW collection
pub fn propagateAll(self: anytype) void {
    while (propagateOne(self)) {}
}

// Backward barrier: when black parent references white child,
// push parent back to gray list to rescan later.
//
// Why backward (not forward)?
// - Forward: mark child immediately → may miss other white refs from same parent
// - Backward: rescan parent → catches all children in one pass
// - Backward is simpler and more robust for Lua's dynamic writes

/// Backward barrier for object references
/// Call when: parent[field] = child (where child may be white)
///
/// Invariant: black object must not reference white object
/// Solution: push black parent back to gray for re-scanning
pub fn barrierBack(self: anytype, parent: *GCObject, child: *GCObject) void {
    // Only needed during mark phase
    if (self.gc_state != .mark) return;

    // Check: parent is black AND child is white
    if (isBlack(self, parent) and isWhite(self, child)) {
        // Push parent back to gray
        parent.in_gray = true;
        parent.gray_next = self.gray_list;
        self.gray_list = parent;
    }
}

/// Backward barrier for TValue references
/// Call when: parent[field] = value (where value may contain white object)
pub fn barrierBackValue(self: anytype, parent: *GCObject, value: TValue) void {
    if (value == .object) {
        barrierBack(self, parent, value.object);
    }
}

/// Prepare for a new GC cycle (called before VM marks roots)
pub fn beginCollection(self: anytype) void {
    // Flip mark - all objects become white implicitly (O(1) vs O(n))
    flipMark(self);

    // Clear gray list
    self.gray_list = null;

    // Clear weak tables list from previous cycle
    self.weak_tables.clearRetainingCapacity();

    // Set state to mark phase
    self.gc_state = .mark;
}

/// Complete collection: ephemeron propagation, sweep, cleanup (called after marking)
fn finishCollection(self: anytype) void {
    // Propagate all gray objects (non-recursive traversal)
    propagateAll(self);

    // Propagate ephemerons until stable
    // For weak-key tables, values are only marked if their keys are marked
    while (self.propagateEphemerons()) {
        // Ephemeron propagation may add more gray objects
        propagateAll(self);
    }

    // Enqueue __gc finalizers for newly unreachable objects
    // This also marks them to keep alive until finalization.
    self.enqueueFinalizers();

    // Newly enqueued finalizers can add references
    propagateAll(self);
    while (self.propagateEphemerons()) {
        propagateAll(self);
    }

    // Clean dead entries from weak tables
    self.cleanWeakTables();

    // Set state to sweep phase
    self.gc_state = .sweep;

    // Sweep phase
    self.sweep();

    // Return to idle state
    self.gc_state = .idle;

    // Adjust next GC threshold based on survival rate
    self.next_gc = @max(
        @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.bytes_allocated)) * self.gc_multiplier)),
        self.gc_min_threshold,
    );
}

/// Mark all values in a stack slice as reachable
pub fn markStack(self: anytype, stack: []const TValue) void {
    for (stack) |value| {
        markValue(self, value);
    }
}

/// Mark constants array (e.g., from Proto.k)
pub fn markConstants(self: anytype, constants: []const TValue) void {
    for (constants) |value| {
        markValue(self, value);
    }
}

/// Mark a TValue if it contains a GC object (adds to gray list)
pub fn markValue(self: anytype, value: TValue) void {
    markGrayValue(self, value);
}

/// Mark a ProtoObject (GC-managed prototype)
///
/// GC SAFETY: This function marks the proto itself, its constants (k),
/// and nested ProtoObjects. All are now GC-managed.
pub fn markProtoObject(self: anytype, proto: *ProtoObject) void {
    markGray(self, &proto.header);
}

/// Run a full GC cycle: mark all roots via providers, then sweep
pub fn collect(self: anytype) void {
    // Prepare for new GC cycle
    beginCollection(self);

    // Mark phase: each provider marks its roots
    for (self.root_providers.items) |provider| {
        provider.markRoots(self);
    }

    // Mark shared metatables (global GC state)
    if (self.shared_mt.string) |mt| markGray(self, &mt.header);
    if (self.shared_mt.number) |mt| markGray(self, &mt.header);
    if (self.shared_mt.boolean) |mt| markGray(self, &mt.header);
    if (self.shared_mt.function) |mt| markGray(self, &mt.header);
    if (self.shared_mt.nil) |mt| markGray(self, &mt.header);

    // Mark metamethod key strings (must survive GC for metamethod dispatch)
    if (self.mm_keys_initialized) {
        for (self.mm_keys.strings) |str| {
            markGray(self, &str.header);
        }
    }

    // Mark queued finalizers (objects + __gc functions)
    self.markFinalizerQueue();

    // Finish: ephemeron propagation, weak table cleanup, sweep
    finishCollection(self);
}
