const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const TableObject = @import("../runtime/gc/object.zig").TableObject;
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");
const VM = @import("../vm/vm.zig").VM;

/// Default search path (fallback if package.path is not set)
const DEFAULT_PATH = "./?.lua;./?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua";

/// Lua 5.4 Module System
/// Corresponds to Lua manual chapter "Modules"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.3
///
/// require(modname) - Loads the given module
/// 1. Checks package.loaded[modname]
/// 2. Checks package.preload[modname]
/// 3. Searches using package.path
/// 4. Caches result in package.loaded
pub fn nativeRequire(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'require' (string expected)");
    }

    const modname_arg = vm.stack[vm.base + func_reg + 1];
    const modname = if (modname_arg.asString()) |str_obj|
        str_obj.asSlice()
    else {
        return vm.raiseString("bad argument #1 to 'require' (string expected)");
    };

    // Get package table
    const package_key = try vm.gc().allocString("package");
    const package_table = if (vm.globals().get(TValue.fromString(package_key))) |v|
        v.asTable()
    else
        null;

    // Get package.loaded
    var loaded_table: ?*TableObject = null;
    if (package_table) |pkg| {
        const loaded_key = try vm.gc().allocString("loaded");
        if (pkg.get(TValue.fromString(loaded_key))) |v| {
            loaded_table = v.asTable();
        }
    }

    // Create loaded table if it doesn't exist
    if (loaded_table == null) {
        loaded_table = try vm.gc().allocTable();
        if (package_table) |pkg| {
            const loaded_key = try vm.gc().allocString("loaded");
            try pkg.set(TValue.fromString(loaded_key), TValue.fromTable(loaded_table.?));
        }
    }

    // Step 1: Check package.loaded[modname]
    const mod_key = try vm.gc().allocString(modname);
    if (loaded_table.?.get(TValue.fromString(mod_key))) |cached| {
        if (!cached.isNil()) {
            if (nresults > 0) {
                vm.stack[vm.base + func_reg] = cached;
            }
            return;
        }
    }

    // Step 2: Check package.preload[modname]
    if (package_table) |pkg| {
        const preload_key = try vm.gc().allocString("preload");
        if (pkg.get(TValue.fromString(preload_key))) |preload_val| {
            if (preload_val.asTable()) |preload| {
                if (preload.get(TValue.fromString(mod_key))) |loader| {
                    if (!loader.isNil()) {
                        // Call the preload function with modname as argument
                        const result = try call.callValue(vm, loader, &[_]TValue{TValue.fromString(mod_key)});

                        // Cache the result
                        const cache_value = if (result.isNil()) TValue{ .boolean = true } else result;
                        try loaded_table.?.set(TValue.fromString(mod_key), cache_value);

                        if (nresults > 0) {
                            vm.stack[vm.base + func_reg] = result;
                        }
                        return;
                    }
                }
            }
        }
    }

    // Step 3: Check for built-in modules (return global table if it exists)
    const builtin_modules = [_][]const u8{ "debug", "string", "table", "math", "io", "os", "coroutine", "utf8", "package" };
    for (builtin_modules) |builtin| {
        if (std.mem.eql(u8, modname, builtin)) {
            const builtin_key = try vm.gc().allocString(builtin);
            if (vm.globals().get(TValue.fromString(builtin_key))) |global_val| {
                // Cache it
                try loaded_table.?.set(TValue.fromString(mod_key), global_val);
                if (nresults > 0) {
                    vm.stack[vm.base + func_reg] = global_val;
                }
                return;
            }
        }
    }

    // Step 4: Search for module file using package.path
    const search_path = getPackagePath(package_table) orelse DEFAULT_PATH;

    var path_buf: [1024]u8 = undefined;
    var path_len: usize = 0;
    var err_buf: [2048]u8 = undefined;
    var err_pos: usize = 0;

    if (!searchPathImpl(modname, search_path, '.', '/', &path_buf, &path_len, &err_buf, &err_pos)) {
        // Build error message
        var msg_buf: [2100]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "module '{s}' not found:{s}", .{ modname, err_buf[0..err_pos] }) catch "module not found";
        return vm.raiseString(msg);
    }

    // Load and execute the module file
    const result = try loadModuleFile(vm, path_buf[0..path_len], mod_key, loaded_table.?);

    // Return the result
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// Get package.path string, or null if not available
fn getPackagePath(package_table: ?*TableObject) ?[]const u8 {
    const pkg = package_table orelse return null;
    const path_key_bytes = "path";
    // We can't allocate here, so we use a direct approach via hash_part iterator
    var iter = pkg.hash_part.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.*.asString()) |key_str| {
            if (std.mem.eql(u8, key_str.asSlice(), path_key_bytes)) {
                if (entry.value_ptr.*.asString()) |val_str| {
                    return val_str.asSlice();
                }
            }
        }
    }
    return null;
}

/// Load a module from file, execute it, and cache the result
fn loadModuleFile(vm: *VM, filename: []const u8, mod_key: anytype, loaded_table: *TableObject) !TValue {
    // Copy filename to stable buffer
    var filename_copy: [1024]u8 = undefined;
    const len = @min(filename.len, filename_copy.len);
    @memcpy(filename_copy[0..len], filename[0..len]);

    // Open and read the file
    const file = std.fs.cwd().openFile(filename_copy[0..len], .{}) catch {
        return vm.raiseString("cannot open module file");
    };
    defer file.close();

    const source = file.readToEndAlloc(vm.gc().allocator, 1024 * 1024 * 10) catch {
        return vm.raiseString("cannot read module file");
    };
    defer vm.gc().allocator.free(source);

    // Compile the source
    const compile_result = pipeline.compile(vm.gc().allocator, source, .{});
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.gc().allocator);
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "{s}:{d}: {s}", .{
                filename_copy[0..len], e.line, e.message,
            }) catch "syntax error in module";
            return vm.raiseString(msg);
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(vm.gc().allocator, raw_proto);

    // Materialize to Proto
    const proto = pipeline.materialize(&raw_proto, vm.gc(), vm.gc().allocator) catch {
        return vm.raiseString("failed to load module");
    };

    // Create closure
    const closure = try vm.gc().allocClosure(proto);

    // Set up _ENV upvalue
    if (proto.nups > 0) {
        const env_upval = try vm.gc().allocClosedUpvalue(TValue.fromTable(vm.globals()));
        closure.upvalues[0] = env_upval;
    }

    const func_val = TValue.fromClosure(closure);

    // Execute the module - LuaException propagates up
    const result = try call.callValue(vm, func_val, &[_]TValue{});

    // Cache the result (use true if module returns nil)
    const cache_value = if (result.isNil()) TValue{ .boolean = true } else result;
    try loaded_table.set(TValue.fromString(mod_key), cache_value);

    return result;
}

/// package.loadlib(libname, funcname) - Dynamically links with C library libname
/// Moonquakes does not support C library loading - returns nil + error
pub fn nativePackageLoadlib(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Validate arguments exist (for proper error messages)
    if (nargs < 2) {
        return vm.raiseString("bad argument #1 to 'loadlib' (string expected)");
    }

    const libname_arg = vm.stack[vm.base + func_reg + 1];
    if (libname_arg.asString() == null) {
        return vm.raiseString("bad argument #1 to 'loadlib' (string expected)");
    }

    const funcname_arg = vm.stack[vm.base + func_reg + 2];
    if (funcname_arg.asString() == null) {
        return vm.raiseString("bad argument #2 to 'loadlib' (string expected)");
    }

    // Moonquakes is a pure Zig implementation - no C library support
    // Return nil, error_message (Lua convention for loadlib failures)
    vm.stack[vm.base + func_reg] = .nil;
    if (nresults > 1) {
        const err_str = try vm.gc().allocString("C libraries not supported");
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
    }
}

/// package.searchpath(name, path [, sep [, rep]]) - Searches for name in given path
/// Returns first matching file path, or nil + error message
pub fn nativePackageSearchpath(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        return vm.raiseString("bad argument #1 to 'searchpath' (string expected)");
    }

    const name_arg = vm.stack[vm.base + func_reg + 1];
    const path_arg = vm.stack[vm.base + func_reg + 2];

    const name = if (name_arg.asString()) |s| s.asSlice() else {
        return vm.raiseString("bad argument #1 to 'searchpath' (string expected)");
    };
    const path = if (path_arg.asString()) |s| s.asSlice() else {
        return vm.raiseString("bad argument #2 to 'searchpath' (string expected)");
    };

    // Optional sep (default ".")
    const sep: u8 = if (nargs >= 3) blk: {
        const sep_arg = vm.stack[vm.base + func_reg + 3];
        if (sep_arg.asString()) |s| {
            const slice = s.asSlice();
            break :blk if (slice.len > 0) slice[0] else '.';
        }
        break :blk '.';
    } else '.';

    // Optional rep (default "/")
    const rep: u8 = if (nargs >= 4) blk: {
        const rep_arg = vm.stack[vm.base + func_reg + 4];
        if (rep_arg.asString()) |s| {
            const slice = s.asSlice();
            break :blk if (slice.len > 0) slice[0] else '/';
        }
        break :blk '/';
    } else '/';

    // Search for the file using the path template
    var out_buf: [1024]u8 = undefined;
    var out_len: usize = 0;
    var err_buf: [2048]u8 = undefined;
    var err_pos: usize = 0;

    if (searchPathImpl(name, path, sep, rep, &out_buf, &out_len, &err_buf, &err_pos)) {
        // Return the found path
        const path_str = try vm.gc().allocString(out_buf[0..out_len]);
        vm.stack[vm.base + func_reg] = TValue.fromString(path_str);
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .nil;
        }
    } else {
        // Return nil + error message
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString(err_buf[0..err_pos]);
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
    }
}

/// Core path search implementation
/// Writes found path to out_buf and returns the slice, or null if not found
/// Error details are accumulated in err_buf
fn searchPathImpl(
    name: []const u8,
    path: []const u8,
    sep: u8,
    rep: u8,
    out_buf: []u8,
    out_len: *usize,
    err_buf: []u8,
    err_pos: *usize,
) bool {
    // Replace sep with rep in name
    var name_buf: [512]u8 = undefined;
    var name_len: usize = 0;
    for (name) |c| {
        if (name_len >= name_buf.len) break;
        name_buf[name_len] = if (c == sep) rep else c;
        name_len += 1;
    }
    const replaced_name = name_buf[0..name_len];

    // Split path by semicolons and try each template
    var path_iter = std.mem.splitScalar(u8, path, ';');
    while (path_iter.next()) |template| {
        // Skip empty templates
        const trimmed = std.mem.trim(u8, template, " \t");
        if (trimmed.len == 0) continue;

        // Replace '?' with the name directly into out_buf
        var pos: usize = 0;
        for (trimmed) |c| {
            if (pos >= out_buf.len - replaced_name.len) break;
            if (c == '?') {
                @memcpy(out_buf[pos..][0..replaced_name.len], replaced_name);
                pos += replaced_name.len;
            } else {
                out_buf[pos] = c;
                pos += 1;
            }
        }
        const filename = out_buf[0..pos];

        // Try to open the file
        if (std.fs.cwd().openFile(filename, .{})) |file| {
            file.close();
            // Found - set output length and return success
            out_len.* = pos;
            return true;
        } else |_| {
            // Record error: "no file 'filename'"
            const prefix = "\n\tno file '";
            const suffix = "'";
            if (err_pos.* + prefix.len + filename.len + suffix.len < err_buf.len) {
                @memcpy(err_buf[err_pos.*..][0..prefix.len], prefix);
                err_pos.* += prefix.len;
                @memcpy(err_buf[err_pos.*..][0..filename.len], filename);
                err_pos.* += filename.len;
                @memcpy(err_buf[err_pos.*..][0..suffix.len], suffix);
                err_pos.* += suffix.len;
            }
        }
    }

    return false;
}

// Package library constants and tables are set up in dispatch.zig:
// - package.config - Configuration information
// - package.cpath - Path used by require to search for C loaders
// - package.path - Path used by require to search for Lua loaders
// - package.loaded - Table of already loaded modules
// - package.preload - Table of preloaded modules
// - package.searchers - Table of searcher functions used by require
