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

const std = @import("std");
const builtin = @import("builtin");
const object = @import("object.zig");
const GCObject = object.GCObject;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const TValue = @import("../value.zig").TValue;
const metamethod = @import("../../vm/metamethod.zig");
const SharedMetatables = metamethod.SharedMetatables;
const MetamethodKeys = metamethod.MetamethodKeys;

const alloc_mod = @import("alloc.zig");
const mark_mod = @import("mark.zig");
const sweep_mod = @import("sweep.zig");
const finalizer_mod = @import("finalizer.zig");
const weak_mod = @import("weak.zig");

/// GC State Machine for incremental collection
/// idle → mark → sweep → idle
pub const GCState = enum(u8) {
    /// No collection in progress
    idle,
    /// Mark phase: traversing from roots, building gray list
    mark,
    /// Sweep phase: freeing white objects
    sweep,
};

// Initial GC threshold - collection runs when bytes_allocated exceeds this
// After collection, threshold adjusts based on survival rate (gc_multiplier)
const GC_THRESHOLD = 256 * 1024; // 256KB initial threshold

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
};

/// Executor for __gc finalizers.
/// Separate from RootProvider to keep responsibilities clear.
pub const FinalizerExecutor = struct {
    ptr: *anyopaque,
    callValue: *const fn (ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue,

    pub fn init(ptr: *anyopaque, callValue: *const fn (ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue) FinalizerExecutor {
        return .{
            .ptr = ptr,
            .callValue = callValue,
        };
    }
};

const FinalizerItem = struct {
    func: TValue,
    obj: *GCObject,
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

    /// Queue of pending __gc finalizers (deferred execution)
    finalizer_queue: std.ArrayListUnmanaged(FinalizerItem),

    /// Active executor for running finalizers (typically current VM)
    finalizer_executor: ?FinalizerExecutor = null,

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

    /// Current state in the GC cycle
    gc_state: GCState = .idle,

    /// Current mark (flip mark scheme)
    /// Object is marked if: obj.mark_bit == current_mark
    /// Avoids O(n) sweep reset by flipping instead of clearing
    current_mark: bool = false,

    /// Gray list head for incremental marking
    /// Gray objects: marked but children not yet scanned
    gray_list: ?*GCObject = null,

    /// Sweep cursor for incremental sweep (current object being examined)
    sweep_cursor: ?*GCObject = null,

    /// Previous object in sweep (to update .next pointer)
    sweep_prev: ?*GCObject = null,

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .objects = null,
            .strings = std.StringHashMap(*StringObject).init(allocator),
            .bytes_allocated = 0,
            .next_gc = GC_THRESHOLD,
            .root_providers = .{},
            .finalizer_queue = .{},
            .finalizer_executor = null,
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

    /// Set or clear the active finalizer executor.
    /// When null, finalizers are queued but not executed.
    pub fn setFinalizerExecutor(self: *GC, executor: ?FinalizerExecutor) void {
        self.finalizer_executor = executor;
    }

    /// True if there are pending finalizers waiting to run.
    pub fn hasPendingFinalizers(self: *const GC) bool {
        return self.finalizer_queue.items.len > 0;
    }

    /// Drain all pending finalizers using the active executor.
    /// Safe to call at VM "safe points" (between instructions, resume boundaries).
    pub fn drainFinalizers(self: *GC) void {
        const executor = self.finalizer_executor orelse return;
        if (self.finalizer_queue.items.len == 0) return;

        // Inhibit GC during finalizer execution to prevent recursive collection.
        self.gc_inhibit += 1;
        defer self.gc_inhibit -= 1;

        for (self.finalizer_queue.items) |item| {
            const obj_val: TValue = switch (item.obj.type) {
                .table => TValue.fromTable(@fieldParentPtr("header", item.obj)),
                .userdata => TValue.fromUserdata(@fieldParentPtr("header", item.obj)),
                else => continue,
            };
            _ = executor.callValue(executor.ptr, &item.func, &[_]TValue{obj_val}) catch {};
            // Note: finalizer_queued stays true to prevent re-finalization.
            // Lua semantics: once finalized, object is not finalized again
            // (unless setmetatable is called to set a new __gc).
        }

        self.finalizer_queue.clearRetainingCapacity();
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

        // Clear finalizer queue
        self.finalizer_queue.deinit(self.allocator);

        // Free all remaining objects without mark/sweep
        // (no need to determine liveness at program exit)
        var current = self.objects;
        while (current) |obj| {
            const next = obj.next;
            self.freeObjectFinal(obj);
            current = next;
        }
    }

    /// Force garbage collection (for debugging/testing)
    /// Runs a full GC cycle: mark all roots via providers, then sweep.
    pub fn forceGC(self: *GC) void {
        self.collect();
    }

    /// Manually mark an object as reachable (for testing / root marking)
    /// Uses gray list for non-recursive marking
    pub fn mark(self: *GC, obj: *GCObject) void {
        self.markGray(obj);
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

    // Method aliases (implementation lives in submodules)
    pub const isMarked = mark_mod.isMarked;
    pub const isWhite = mark_mod.isWhite;
    pub const isGray = mark_mod.isGray;
    pub const isBlack = mark_mod.isBlack;
    pub const flipMark = mark_mod.flipMark;
    pub const markGray = mark_mod.markGray;
    pub const markGrayValue = mark_mod.markGrayValue;
    pub const grayListEmpty = mark_mod.grayListEmpty;
    pub const propagateOne = mark_mod.propagateOne;
    pub const propagateAll = mark_mod.propagateAll;
    pub const barrierBack = mark_mod.barrierBack;
    pub const barrierBackValue = mark_mod.barrierBackValue;
    pub const beginCollection = mark_mod.beginCollection;
    pub const markStack = mark_mod.markStack;
    pub const markConstants = mark_mod.markConstants;
    pub const markValue = mark_mod.markValue;
    pub const markProtoObject = mark_mod.markProtoObject;
    pub const collect = mark_mod.collect;

    pub const parseWeakMode = weak_mod.parseWeakMode;
    pub const propagateEphemerons = weak_mod.propagateEphemerons;
    pub const cleanWeakTables = weak_mod.cleanWeakTables;

    pub const markFinalizerQueue = finalizer_mod.markFinalizerQueue;
    pub const enqueueFinalizers = finalizer_mod.enqueueFinalizers;

    pub const sweep = sweep_mod.sweep;
    pub const freeObjectFinal = sweep_mod.freeObjectFinal;

    pub const allocObject = alloc_mod.allocObject;
    pub const newObjectHeader = alloc_mod.newObjectHeader;
    pub const allocString = alloc_mod.allocString;
    pub const allocTable = alloc_mod.allocTable;
    pub const allocClosure = alloc_mod.allocClosure;
    pub const allocProto = alloc_mod.allocProto;
    pub const allocUpvalue = alloc_mod.allocUpvalue;
    pub const allocClosedUpvalue = alloc_mod.allocClosedUpvalue;
    pub const allocNativeClosure = alloc_mod.allocNativeClosure;
    pub const allocUserdata = alloc_mod.allocUserdata;
    pub const allocThread = alloc_mod.allocThread;
};
