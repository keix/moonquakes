const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Module System
/// Corresponds to Lua manual chapter "Modules"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.3
/// require(modname) - Loads the given module
pub fn nativeRequire(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement require
    // Loads and runs libraries, returns any value returned by the searcher
    // Uses package.searchers to find module loader
}

/// package.loadlib(libname, funcname) - Dynamically links with C library libname
pub fn nativePackageLoadlib(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement package.loadlib
    // Links with host program and calls funcname as C function
}

/// package.searchpath(name, path [, sep [, rep]]) - Searches for name in given path
pub fn nativePackageSearchpath(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement package.searchpath
    // Searches for name in path using path separators
}

// Package library constants and tables are set up in dispatch.zig:
// - package.config - Configuration information
// - package.cpath - Path used by require to search for C loaders
// - package.path - Path used by require to search for Lua loaders
// - package.loaded - Table of already loaded modules
// - package.preload - Table of preloaded modules
// - package.searchers - Table of searcher functions used by require
