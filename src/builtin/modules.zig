const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");
const RuntimeError = @import("error.zig").RuntimeError;

// Module cache key for package.loaded equivalent
const LOADED_KEY = "_loaded";

/// Lua 5.4 Module System
/// Corresponds to Lua manual chapter "Modules"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.3
/// require(modname) - Loads the given module
/// Minimal implementation: searches for modname.lua in current directory
/// Caches results in a global _loaded table
pub fn nativeRequire(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        vm.lua_error_msg = try vm.gc.allocString("bad argument #1 to 'require' (string expected)");
        return RuntimeError.RuntimeError;
    }

    const modname_arg = vm.stack[vm.base + func_reg + 1];
    const modname = if (modname_arg.asString()) |str_obj|
        str_obj.asSlice()
    else {
        vm.lua_error_msg = try vm.gc.allocString("bad argument #1 to 'require' (string expected)");
        return RuntimeError.RuntimeError;
    };

    // Get or create _loaded cache table in globals
    const loaded_key = try vm.gc.allocString(LOADED_KEY);
    var loaded_table = if (vm.globals.get(loaded_key)) |v|
        v.asTable()
    else
        null;

    if (loaded_table == null) {
        loaded_table = try vm.gc.allocTable();
        try vm.globals.set(loaded_key, TValue.fromTable(loaded_table.?));
    }

    // Check if module is already loaded
    const mod_key = try vm.gc.allocString(modname);
    if (loaded_table.?.get(mod_key)) |cached| {
        if (!cached.isNil()) {
            if (nresults > 0) {
                vm.stack[vm.base + func_reg] = cached;
            }
            return;
        }
    }

    // Check for built-in modules (return global table if it exists)
    const builtin_modules = [_][]const u8{ "debug", "string", "table", "math", "io", "os", "coroutine", "utf8", "package" };
    for (builtin_modules) |builtin| {
        if (std.mem.eql(u8, modname, builtin)) {
            // Return the global table
            if (vm.globals.get(mod_key)) |global_val| {
                // Cache it
                try loaded_table.?.set(mod_key, global_val);
                if (nresults > 0) {
                    vm.stack[vm.base + func_reg] = global_val;
                }
                return;
            }
        }
    }

    // Search for module file
    // Try: modname.lua, modname/init.lua
    var filename_buf: [512]u8 = undefined;

    var found_file: ?std.fs.File = null;
    var found_source: ?[]const u8 = null;

    // Try modname.lua
    if (found_file == null) {
        @memcpy(filename_buf[0..modname.len], modname);
        const suffix = ".lua";
        @memcpy(filename_buf[modname.len..][0..suffix.len], suffix);
        const filename = filename_buf[0 .. modname.len + suffix.len];

        if (std.fs.cwd().openFile(filename, .{})) |file| {
            found_file = file;
            found_source = file.readToEndAlloc(vm.allocator, 1024 * 1024 * 10) catch null;
            if (found_source == null) {
                file.close();
                found_file = null;
            }
        } else |_| {}
    }

    // Try modname/init.lua
    if (found_file == null) {
        @memcpy(filename_buf[0..modname.len], modname);
        const suffix = "/init.lua";
        @memcpy(filename_buf[modname.len..][0..suffix.len], suffix);
        const filename = filename_buf[0 .. modname.len + suffix.len];

        if (std.fs.cwd().openFile(filename, .{})) |file| {
            found_file = file;
            found_source = file.readToEndAlloc(vm.allocator, 1024 * 1024 * 10) catch null;
            if (found_source == null) {
                file.close();
                found_file = null;
            }
        } else |_| {}
    }

    if (found_file == null or found_source == null) {
        vm.lua_error_msg = try vm.gc.allocString("module not found");
        return RuntimeError.RuntimeError;
    }
    defer found_file.?.close();
    defer vm.allocator.free(found_source.?);

    // Compile the source
    const compile_result = pipeline.compile(vm.allocator, found_source.?, .{});
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.allocator);
            // Format error message: "module:line: message"
            const err_msg = std.fmt.allocPrint(vm.allocator, "{s}:{d}: {s}", .{
                "module", e.line, e.message,
            }) catch "syntax error in module";
            vm.lua_error_msg = vm.gc.allocString(err_msg) catch null;
            vm.allocator.free(err_msg);
            return RuntimeError.RuntimeError;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(vm.allocator, raw_proto);

    // Materialize to Proto
    const proto = pipeline.materialize(&raw_proto, &vm.gc, vm.allocator) catch {
        vm.lua_error_msg = try vm.gc.allocString("failed to load module");
        return RuntimeError.RuntimeError;
    };

    // Create closure and execute
    const closure = try vm.gc.allocClosure(proto);
    const func_val = TValue.fromClosure(closure);

    // Execute the module
    const result = call.callValue(vm, func_val, &[_]TValue{}) catch |err| {
        if (vm.lua_error_msg == null) {
            vm.lua_error_msg = try vm.gc.allocString(@errorName(err));
        }
        return RuntimeError.RuntimeError;
    };

    // Cache the result (use true if module returns nil)
    const cache_value = if (result.isNil()) TValue{ .boolean = true } else result;
    try loaded_table.?.set(mod_key, cache_value);

    // Return the result
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
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
