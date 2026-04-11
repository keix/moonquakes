//! Module-system builtin functions for `require` and `package`.
//!
//! Search-path and loader helpers stay near the top of the file.
//! Dispatcher entrypoints are grouped below.

const std = @import("std");
const object = @import("../runtime/gc/object.zig");
const TValue = @import("../runtime/value.zig").TValue;
const TableObject = object.TableObject;
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");
const VM = @import("../vm/vm.zig").VM;

fn tableSet(vm: *VM, table: *TableObject, key: TValue, value: TValue) !void {
    try vm.gc().tableSet(table, key, value);
}

/// Default search path (fallback if package.path is not set)
const DEFAULT_PATH = "./?.lua;./?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua";

const PackagePath = union(enum) {
    missing,
    path: []const u8,
    invalid_type,
};

/// Get package string field value with type status for require validation.
fn getPackageStringField(package_table: ?*TableObject, field_name: []const u8) PackagePath {
    const pkg = package_table orelse return .missing;
    // We can't allocate here, so we use a direct approach via hash_part iterator
    var iter = pkg.hash_part.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.*.asString()) |key_str| {
            if (std.mem.eql(u8, key_str.asSlice(), field_name)) {
                if (entry.value_ptr.*.asString()) |val_str| {
                    return .{ .path = val_str.asSlice() };
                }
                return .invalid_type;
            }
        }
    }
    return .missing;
}

/// Build the effective search path for require.
/// Prepends the running script's directory (arg[0]) when available.
fn buildRequireSearchPath(vm: *VM, base_path: []const u8, prepend_script_dir: bool, out_buf: []u8) []const u8 {
    if (!prepend_script_dir) return base_path;
    const script_dir = getScriptDir(vm) orelse return base_path;

    // If script has no directory component, base path already covers "./?.lua".
    if (script_dir.len == 0 or std.mem.eql(u8, script_dir, ".")) {
        return base_path;
    }

    return std.fmt.bufPrint(out_buf, "{s}/?.lua;{s}/?/init.lua;{s}", .{ script_dir, script_dir, base_path }) catch base_path;
}

fn appendErrorDetail(err_buf: []u8, err_pos: *usize, line: []const u8) void {
    if (err_pos.* >= err_buf.len) return;
    const remaining = err_buf.len - err_pos.*;
    const to_copy = @min(remaining, line.len);
    @memcpy(err_buf[err_pos.*..][0..to_copy], line[0..to_copy]);
    err_pos.* += to_copy;
}

/// Resolve script directory from arg[0].
fn getScriptDir(vm: *VM) ?[]const u8 {
    const arg_key = vm.gc().allocString("arg") catch return null;
    const arg_table_val = vm.globals().get(TValue.fromString(arg_key)) orelse return null;
    const arg_table = arg_table_val.asTable() orelse return null;

    const script_val = arg_table.get(.{ .integer = 0 }) orelse return null;
    const script_str = script_val.asString() orelse return null;
    const script_name = script_str.asSlice();

    return std.fs.path.dirname(script_name);
}

/// Load a module from file, execute it, and cache the result
fn loadModuleFile(vm: *VM, filename: []const u8, mod_key: anytype) !TValue {
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
    const compile_result = vm.rt.compile_ctx.compile(source, .{});
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(vm.gc().allocator);
            var msg_buf: [768]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "error loading module '{s}' from file '{s}':\n\t{s}:{d}: {s}", .{
                mod_key.asSlice(),
                filename_copy[0..len],
                filename_copy[0..len],
                e.line,
                e.message,
            }) catch "error loading module";
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

    // GC safety: closure/upvalue/filename allocations below must be atomic with
    // respect to collection because these objects are not yet rooted in VM stack.
    var gc_inhibited = true;
    vm.gc().inhibitGC();
    defer if (gc_inhibited) vm.gc().allowGC();

    // Create closure
    const closure = try vm.gc().allocClosure(proto);

    // Set up _ENV upvalue
    if (proto.nups > 0) {
        vm.gc().initClosedUpvalue(closure.upvalues[0], TValue.fromTable(vm.globals()));
    }

    const func_val = TValue.fromClosure(closure);

    const filename_obj = try vm.gc().allocString(filename_copy[0..len]);
    vm.gc().allowGC();
    gc_inhibited = false;

    // Execute the module - LuaException propagates up
    return call.callValue(vm, func_val, &[_]TValue{
        TValue.fromString(mod_key),
        TValue.fromString(filename_obj),
    });
}

/// Core path search implementation
/// Writes found path to out_buf and returns the slice, or null if not found
/// Error details are accumulated in err_buf
fn searchPathImpl(
    name: []const u8,
    path: []const u8,
    sep: []const u8,
    rep: []const u8,
    out_buf: []u8,
    out_len: *usize,
    err_buf: []u8,
    err_pos: *usize,
) bool {
    // Replace all occurrences of sep with rep in name.
    var name_buf: [4096]u8 = undefined;
    var name_len: usize = 0;
    if (sep.len == 0) {
        const copy_len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..copy_len], name[0..copy_len]);
        name_len = copy_len;
    } else {
        var i: usize = 0;
        while (i < name.len) {
            if (std.mem.startsWith(u8, name[i..], sep)) {
                if (name_len + rep.len > name_buf.len) break;
                @memcpy(name_buf[name_len..][0..rep.len], rep);
                name_len += rep.len;
                i += sep.len;
            } else {
                if (name_len >= name_buf.len) break;
                name_buf[name_len] = name[i];
                name_len += 1;
                i += 1;
            }
        }
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
            if (c == '?') {
                if (pos + replaced_name.len > out_buf.len) break;
                @memcpy(out_buf[pos..][0..replaced_name.len], replaced_name);
                pos += replaced_name.len;
            } else {
                if (pos >= out_buf.len) break;
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
            } else if (err_pos.* < err_buf.len) {
                // Keep line count semantics even when message body is truncated.
                err_buf[err_pos.*] = '\n';
                err_pos.* += 1;
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

// Dispatcher entrypoints.

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

    const hidden_package_key = try vm.gc().allocString("__moonquakes_package");
    var package_table: ?*TableObject = null;
    if (vm.globals().get(TValue.fromString(hidden_package_key))) |v| {
        package_table = v.asTable();
    }
    if (package_table == null) {
        const package_key = try vm.gc().allocString("package");
        if (vm.globals().get(TValue.fromString(package_key))) |v| {
            package_table = v.asTable();
        }
    }

    var loaded_table: ?*TableObject = null;
    if (package_table) |pkg| {
        const loaded_key = try vm.gc().allocString("loaded");
        if (pkg.get(TValue.fromString(loaded_key))) |v| {
            loaded_table = v.asTable();
        }
    }

    if (loaded_table == null) {
        loaded_table = try vm.gc().allocTable();
        if (package_table) |pkg| {
            const loaded_key = try vm.gc().allocString("loaded");
            try tableSet(vm, pkg, TValue.fromString(loaded_key), TValue.fromTable(loaded_table.?));
        }
    }

    const mod_key = try vm.gc().allocString(modname);
    if (!vm.pushTempRoot(TValue.fromString(mod_key))) return error.OutOfMemory;
    defer vm.popTempRoots(1);
    if (loaded_table.?.get(TValue.fromString(mod_key))) |cached| {
        if (cached.toBoolean()) {
            if (nresults > 0) {
                vm.stack[vm.base + func_reg] = cached;
            }
            if (nresults > 1) {
                vm.stack[vm.base + func_reg + 1] = .nil;
            }
            return;
        }
    }

    if (package_table) |pkg| {
        const searchers_key = try vm.gc().allocString("searchers");
        if (pkg.get(TValue.fromString(searchers_key))) |searchers_val| {
            if (searchers_val.asTable() == null) {
                return vm.raiseString("'package.searchers' must be a table");
            }
        }
    }

    if (package_table) |pkg| {
        const preload_key = try vm.gc().allocString("preload");
        if (pkg.get(TValue.fromString(preload_key))) |preload_val| {
            if (preload_val.asTable()) |preload| {
                if (preload.get(TValue.fromString(mod_key))) |loader| {
                    if (!loader.isNil()) {
                        const preload_loader_data = try vm.gc().allocString(":preload:");
                        const result = try call.callValue(vm, loader, &[_]TValue{
                            TValue.fromString(mod_key),
                            TValue.fromString(preload_loader_data),
                        });

                        if (result.asTable()) |res_table| {
                            const xuxu_key = try vm.gc().allocString("xuxu");
                            if (res_table.get(TValue.fromString(xuxu_key)) == null) {
                                if (vm.globals().get(TValue.fromString(xuxu_key))) |global_xuxu| {
                                    try tableSet(vm, res_table, TValue.fromString(xuxu_key), global_xuxu);
                                }
                            }
                        }
                        if (!result.isNil()) {
                            try tableSet(vm, loaded_table.?, TValue.fromString(mod_key), result);
                        }
                        var require_result = loaded_table.?.get(TValue.fromString(mod_key)) orelse .nil;
                        if (require_result.isNil()) {
                            require_result = TValue{ .boolean = true };
                            try tableSet(vm, loaded_table.?, TValue.fromString(mod_key), require_result);
                        }

                        if (nresults > 0) {
                            vm.stack[vm.base + func_reg] = require_result;
                        }
                        if (nresults > 1) {
                            vm.stack[vm.base + func_reg + 1] = TValue.fromString(preload_loader_data);
                        }
                        return;
                    }
                }
            }
        }
    }

    const builtin_modules = [_][]const u8{ "debug", "string", "table", "math", "io", "os", "coroutine", "utf8", "package" };
    for (builtin_modules) |builtin| {
        if (std.mem.eql(u8, modname, builtin)) {
            const builtin_key = try vm.gc().allocString(builtin);
            if (vm.globals().get(TValue.fromString(builtin_key))) |global_val| {
                try tableSet(vm, loaded_table.?, TValue.fromString(mod_key), global_val);
                if (nresults > 0) {
                    vm.stack[vm.base + func_reg] = global_val;
                }
                if (nresults > 1) {
                    vm.stack[vm.base + func_reg + 1] = .nil;
                }
                return;
            }
        }
    }

    var err_buf: [262144]u8 = undefined;
    var err_pos: usize = 0;

    {
        var line_buf: [256]u8 = undefined;
        const preload_line = std.fmt.bufPrint(&line_buf, "\n\tno field package.preload['{s}']", .{modname}) catch "";
        appendErrorDetail(&err_buf, &err_pos, preload_line);
    }

    const package_path = getPackageStringField(package_table, "path");
    const base_path = switch (package_path) {
        .missing => DEFAULT_PATH,
        .path => |p| p,
        .invalid_type => return vm.raiseString("package.path must be a string"),
    };

    var search_path_buf: [2048]u8 = undefined;
    const search_path = buildRequireSearchPath(vm, base_path, package_path == .missing, &search_path_buf);

    var path_buf: [1024]u8 = undefined;
    var path_len: usize = 0;
    if (searchPathImpl(modname, search_path, ".", "/", &path_buf, &path_len, &err_buf, &err_pos)) {
        const result = try loadModuleFile(vm, path_buf[0..path_len], mod_key);
        if (!result.isNil()) {
            try tableSet(vm, loaded_table.?, TValue.fromString(mod_key), result);
        }
        var require_result = loaded_table.?.get(TValue.fromString(mod_key)) orelse .nil;
        if (require_result.isNil()) {
            require_result = TValue{ .boolean = true };
            try tableSet(vm, loaded_table.?, TValue.fromString(mod_key), require_result);
        }

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = require_result;
        }
        if (nresults > 1) {
            const loader_data = try vm.gc().allocString(path_buf[0..path_len]);
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(loader_data);
        }

        const required_key = try vm.gc().allocString("REQUIRED");
        if (vm.globals().get(TValue.fromString(required_key)) != null) {
            try tableSet(vm, vm.globals(), TValue.fromString(required_key), TValue.fromString(mod_key));
        }
        return;
    }

    const package_cpath = getPackageStringField(package_table, "cpath");
    const cpath = switch (package_cpath) {
        .missing => "",
        .path => |p| p,
        .invalid_type => return vm.raiseString("package.cpath must be a string"),
    };
    if (cpath.len > 0) {
        _ = searchPathImpl(modname, cpath, ".", "/", &path_buf, &path_len, &err_buf, &err_pos);
    }

    var msg_buf: [262512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "module '{s}' not found:{s}", .{ modname, err_buf[0..err_pos] }) catch "module not found";
    return vm.raiseString(msg);
}

/// package.loadlib(libname, funcname) - Dynamically links with C library libname
/// Moonquakes does not support C library loading - returns nil + error
pub fn nativePackageLoadlib(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
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

    vm.stack[vm.base + func_reg] = .nil;
    if (nresults > 1) {
        const err_str = try vm.gc().allocString("C libraries not supported");
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
    }
    if (nresults > 2) {
        const when_str = try vm.gc().allocString("absent");
        vm.stack[vm.base + func_reg + 2] = TValue.fromString(when_str);
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

    const sep: []const u8 = if (nargs >= 3) blk: {
        const sep_arg = vm.stack[vm.base + func_reg + 3];
        if (sep_arg.asString()) |s| {
            break :blk s.asSlice();
        }
        break :blk ".";
    } else ".";

    const rep: []const u8 = if (nargs >= 4) blk: {
        const rep_arg = vm.stack[vm.base + func_reg + 4];
        if (rep_arg.asString()) |s| {
            break :blk s.asSlice();
        }
        break :blk "/";
    } else "/";

    var out_buf: [16384]u8 = undefined;
    var out_len: usize = 0;
    var err_buf: [262144]u8 = undefined;
    var err_pos: usize = 0;

    if (searchPathImpl(name, path, sep, rep, &out_buf, &out_len, &err_buf, &err_pos)) {
        const path_str = try vm.gc().allocString(out_buf[0..out_len]);
        vm.stack[vm.base + func_reg] = TValue.fromString(path_str);
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .nil;
        }
    } else {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString(err_buf[0..err_pos]);
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
    }
}
