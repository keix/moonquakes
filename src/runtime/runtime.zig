//! Runtime - Shared Execution Context
//!
//! Runtime represents the shared world (process-level state) in Moonquakes.
//! Multiple VMs (threads/coroutines) can share a single Runtime.
//!
//! Responsibilities:
//! - GC ownership and management
//! - Global environment (_G, _ENV, builtins)
//! - Registry table
//! - Metamethod keys initialization
//!
//! Architecture:
//!   Runtime (shared) ← VM (thread)
//!   1 Runtime : N VMs (coroutines)

const std = @import("std");
const gc_mod = @import("gc/gc.zig");
const GC = gc_mod.GC;
const RootProvider = gc_mod.RootProvider;
const object = @import("gc/object.zig");
const TableObject = object.TableObject;
const ThreadObject = object.ThreadObject;
const TValue = @import("value.zig").TValue;
const builtin_dispatch = @import("../builtin/dispatch.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    gc: *GC,
    globals: *TableObject,
    registry: *TableObject,

    /// The main thread (first VM created). Set by VM.init.
    main_thread: ?*ThreadObject = null,

    /// Currently executing thread. Changes during coroutine resume/yield.
    current_thread: ?*ThreadObject = null,

    /// Initialize a new Runtime.
    /// Creates GC, globals, registry, and initializes builtin environment.
    pub fn init(allocator: std.mem.Allocator) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        // GC on heap (stable address for VM references)
        const gc = try allocator.create(GC);
        errdefer allocator.destroy(gc);
        gc.* = GC.init(allocator);
        errdefer gc.deinit();

        // Initialize metamethod keys
        try gc.initMetamethodKeys();

        // Create root tables
        const globals = try gc.allocTable();
        const registry = try gc.allocTable();

        self.* = .{
            .allocator = allocator,
            .gc = gc,
            .globals = globals,
            .registry = registry,
        };

        // Register as root provider (must be after self.* is set)
        try gc.addRootProvider(self.rootProvider());

        // Initialize builtin environment (_G, _ENV, print, etc.)
        try builtin_dispatch.initGlobalEnvironment(globals, gc);

        return self;
    }

    /// Clean up Runtime resources.
    pub fn deinit(self: *Runtime) void {
        // Unregister from GC before destruction
        self.gc.removeRootProvider(self.rootProvider());

        // Clean up GC
        self.gc.deinit();
        self.allocator.destroy(self.gc);

        // Clean up self
        self.allocator.destroy(self);
    }

    /// Create a RootProvider for GC marking.
    pub fn rootProvider(self: *Runtime) RootProvider {
        return RootProvider.init(Runtime, self, &runtimeRootProviderVTable);
    }

    /// Set the main thread. Called by VM.init for the first VM.
    pub fn setMainThread(self: *Runtime, thread: *ThreadObject) void {
        self.main_thread = thread;
        self.current_thread = thread;
    }

    /// Get the main thread.
    pub fn getMainThread(self: *Runtime) ?*ThreadObject {
        return self.main_thread;
    }

    /// Get the currently running thread.
    pub fn getCurrentThread(self: *Runtime) ?*ThreadObject {
        return self.current_thread;
    }

    /// Set the currently running thread (for coroutine resume/yield).
    pub fn setCurrentThread(self: *Runtime, thread: *ThreadObject) void {
        self.current_thread = thread;
    }
};

/// VTable for Runtime's RootProvider implementation
const runtimeRootProviderVTable = RootProvider.VTable{
    .markRoots = runtimeMarkRoots,
    .callValue = runtimeCallValue,
};

/// Mark Runtime roots for GC.
/// Called during GC mark phase.
fn runtimeMarkRoots(ctx: *anyopaque, gc: *GC) void {
    const self: *Runtime = @ptrCast(@alignCast(ctx));

    // Mark global environment
    gc.mark(&self.globals.header);

    // Mark registry
    gc.mark(&self.registry.header);

    // Mark thread objects (keeps them alive)
    if (self.main_thread) |mt| {
        gc.mark(&mt.header);
        // Mark current_thread only if different from main_thread
        if (self.current_thread) |ct| {
            if (ct != mt) {
                gc.mark(&ct.header);
            }
        }
    } else if (self.current_thread) |ct| {
        gc.mark(&ct.header);
    }
}

/// Call a Lua value (for __gc finalizers).
/// Runtime doesn't have execution state - this should not be called.
/// The active VM's callValue will be used instead.
fn runtimeCallValue(_: *anyopaque, _: *const TValue, _: []const TValue) anyerror!TValue {
    // Runtime cannot execute code - it has no stack.
    // __gc finalizers are called via VM's root provider.
    return .nil;
}
