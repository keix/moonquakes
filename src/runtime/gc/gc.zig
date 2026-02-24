//! Garbage Collector - Module Umbrella
//!
//! This file re-exports the GC state and interfaces after the split.

pub const GC = @import("state.zig").GC;
pub const GCState = @import("state.zig").GCState;
pub const RootProvider = @import("state.zig").RootProvider;
pub const FinalizerExecutor = @import("state.zig").FinalizerExecutor;
