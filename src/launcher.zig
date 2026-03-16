//! Launcher - Execution Context Setup
//!
//! Prepares VM execution environment before running scripts.
//! Handles runtime-injected globals like `arg`, `_ENV`, etc.
//!
//! This is where "execution conventions" live, not language features.
//! Embedders can use this directly or build their own launcher.

const std = @import("std");
const Runtime = @import("runtime/runtime.zig").Runtime;
const VM = @import("vm/vm.zig").VM;
const GC = @import("runtime/gc/gc.zig").GC;
const TableObject = @import("runtime/gc/object.zig").TableObject;
const TValue = @import("runtime/value.zig").TValue;
const Mnemonics = @import("vm/mnemonics.zig");
const ReturnValue = @import("vm/execution.zig").ReturnValue;
const pipeline = @import("compiler/pipeline.zig");
const call = @import("vm/call.zig");
const metamethod = @import("vm/metamethod.zig");
const owned = @import("runtime/owned.zig");
pub const OwnedReturnValue = owned.OwnedReturnValue;
const DEFAULT_LUA_PATH = "./?.lua;./?/init.lua;/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua";
const DEFAULT_LUA_CPATH = "./?.so;/usr/local/lib/lua/5.4/?.so";

fn errorValueTypeName(value: TValue) []const u8 {
    return switch (value) {
        .nil => "nil",
        .boolean => "boolean",
        .integer, .number => "number",
        .object => |obj| switch (obj.type) {
            .string => "string",
            .table => "table",
            .closure, .native_closure => "function",
            .thread => "thread",
            .userdata, .file => "userdata",
            .proto => "proto",
            .upvalue => "userdata",
        },
    };
}

fn formatErrorValue(vm: *VM, value: TValue) ?[]const u8 {
    if (value.asString()) |s| return s.asSlice();

    if (metamethod.getMetamethod(value, .tostring, &vm.gc().mm_keys, &vm.gc().shared_mt)) |mm| {
        if (!vm.pushTempRoot(mm)) return null;
        if (!vm.pushTempRoot(value)) {
            vm.popTempRoots(1);
            return null;
        }
        defer vm.popTempRoots(2);

        const result = call.callValue(vm, mm, &[_]TValue{value}) catch return null;
        if (result.asString()) |s| return s.asSlice();
        return null;
    }

    return null;
}

fn printUnhandledLuaError(vm: *VM, exec_name: []const u8) void {
    if (formatErrorValue(vm, vm.lua_error_value)) |msg| {
        if (vm.lua_error_value.asString() != null) {
            std.debug.print("{s}\n", .{msg});
        } else {
            std.debug.print("{s}: {s}\n", .{ exec_name, msg });
        }
        return;
    }

    std.debug.print("{s}: error object is a {s} value\n", .{ exec_name, errorValueTypeName(vm.lua_error_value) });
}

fn stripUtf8Bom(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) {
        return bytes[3..];
    }
    return bytes;
}

fn stripInitialHashLine(bytes: []const u8, preserve_newline: bool) []const u8 {
    if (bytes.len == 0 or bytes[0] != '#') return bytes;
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != '\n' and bytes[i] != '\r') : (i += 1) {}
    if (i >= bytes.len) return "";
    if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
        return if (preserve_newline) bytes[i + 1 ..] else bytes[i + 2 ..];
    }
    return if (preserve_newline) bytes[i..] else bytes[i + 1 ..];
}

/// Execution options for script launch
pub const RunOptions = struct {
    /// Executable name/path (becomes arg[-1] in CLI convention)
    exec_name: []const u8 = "",
    /// Script name (becomes arg[0])
    script_name: []const u8 = "",
    /// Script arguments (become arg[1], arg[2], ...)
    args: []const []const u8 = &.{},
    /// Ignore LUA_* environment variables (Lua -E semantics)
    ignore_environment: bool = false,
    /// Enable warnings from startup (CLI -W semantics)
    warnings_enabled: bool = false,
    /// Modules to require before running main chunk (CLI -l)
    preload_modules: []const []const u8 = &.{},
    /// Chunks to execute before main chunk (CLI -e, in parse order)
    exec_chunks: []const []const u8 = &.{},
    /// Values placed at arg[-n]..arg[-1] (CLI tokens before script)
    pre_script_args: []const []const u8 = &.{},
    // Future extensions:
    // env: ?*TableObject = null,
    // preload: []const PreloadModule = &.{},
};

fn getPreferredEnv(allocator: std.mem.Allocator, primary: []const u8, fallback: []const u8) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, primary)) |value| return value else |_| {}
    if (std.process.getEnvVarOwned(allocator, fallback)) |value| return value else |_| {}
    return null;
}

fn expandDoubleSemicolon(allocator: std.mem.Allocator, value: []const u8, default_path: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, value, ";;") == null) return allocator.dupe(u8, value);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (i + 1 < value.len and value[i] == ';' and value[i + 1] == ';') {
            try out.append(allocator, ';');
            try out.appendSlice(allocator, default_path);
            try out.append(allocator, ';');
            i += 2;
            continue;
        }
        try out.append(allocator, value[i]);
        i += 1;
    }
    const expanded = try out.toOwnedSlice(allocator);
    var start: usize = 0;
    var end: usize = expanded.len;
    if (start < end and expanded[start] == ';') start += 1;
    if (end > start and expanded[end - 1] == ';') end -= 1;
    const trimmed = try allocator.dupe(u8, expanded[start..end]);
    allocator.free(expanded);
    return trimmed;
}

fn setPackageStringField(vm: *VM, field: []const u8, value: []const u8) !void {
    const hidden_package_key = try vm.gc().allocString("__moonquakes_package");
    const package_val = vm.globals().get(TValue.fromString(hidden_package_key)) orelse return;
    const package_table = package_val.asTable() orelse return;
    const field_key = try vm.gc().allocString(field);
    const field_val = try vm.gc().allocString(value);
    try package_table.set(TValue.fromString(field_key), TValue.fromString(field_val));
}

pub fn executeInitChunk(vm: *VM, allocator: std.mem.Allocator, source: []const u8, source_name: []const u8) !void {
    const compile_result = pipeline.compile(allocator, source, .{ .source_name = source_name });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(allocator);
            std.debug.print("LUA_INIT:{d}: {s}\n", .{ e.line, e.message });
            return error.CompileFailed;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(allocator, raw_proto);
    const proto = try pipeline.materialize(&raw_proto, vm.gc(), allocator);
    _ = Mnemonics.execute(vm, proto) catch |err| {
        if (err == error.LuaException) {
            if (vm.lua_error_value.asString()) |err_str| {
                std.debug.print("LUA_INIT:1: {s}\n", .{err_str.asSlice()});
            } else {
                std.debug.print("LUA_INIT:1: (error object is not a string)\n", .{});
            }
            return error.CompileFailed;
        }
        return err;
    };
}

pub fn applyEnvironment(vm: *VM, allocator: std.mem.Allocator, ignore_environment: bool) !void {
    if (ignore_environment) return;

    const path_env = getPreferredEnv(allocator, "LUA_PATH_5_4", "LUA_PATH");
    defer if (path_env) |v| allocator.free(v);
    if (path_env) |path| {
        const expanded = try expandDoubleSemicolon(allocator, path, DEFAULT_LUA_PATH);
        defer allocator.free(expanded);
        try setPackageStringField(vm, "path", expanded);
    }

    const cpath_env = getPreferredEnv(allocator, "LUA_CPATH_5_4", "LUA_CPATH");
    defer if (cpath_env) |v| allocator.free(v);
    if (cpath_env) |cpath| {
        const expanded = try expandDoubleSemicolon(allocator, cpath, DEFAULT_LUA_CPATH);
        defer allocator.free(expanded);
        try setPackageStringField(vm, "cpath", expanded);
    }

    const init_env = getPreferredEnv(allocator, "LUA_INIT_5_4", "LUA_INIT");
    defer if (init_env) |v| allocator.free(v);
    if (init_env) |init_src| {
        if (init_src.len == 0) return;
        if (init_src[0] == '@') {
            const init_path = init_src[1..];
            const file = std.fs.cwd().openFile(init_path, .{}) catch {
                std.debug.print("LUA_INIT:1: cannot open {s}\n", .{init_path});
                return error.CompileFailed;
            };
            defer file.close();
            const file_size = try file.getEndPos();
            const init_source = try allocator.alloc(u8, file_size);
            defer allocator.free(init_source);
            _ = try file.readAll(init_source);
            try executeInitChunk(vm, allocator, init_source, "@LUA_INIT");
        } else {
            try executeInitChunk(vm, allocator, init_src, "=LUA_INIT");
        }
    }
}

pub fn runPreloadModule(vm: *VM, module_spec: []const u8) !void {
    var module_name = module_spec;
    var global_name = module_spec;
    if (std.mem.indexOfScalar(u8, module_spec, '=')) |eq| {
        global_name = module_spec[0..eq];
        module_name = module_spec[eq + 1 ..];
    } else if (std.mem.indexOfScalar(u8, module_spec, '-')) |dash| {
        // Lua CLI compatibility: "-l mod-v2" stores module in global "mod".
        global_name = module_spec[0..dash];
    }

    const require_key = try vm.gc().allocString("require");
    const require_val = vm.globals().get(TValue.fromString(require_key)) orelse {
        return vm.raiseString("global 'require' is not available");
    };
    const module_key = try vm.gc().allocString(module_name);
    const result = try call.callValue(vm, require_val, &[_]TValue{TValue.fromString(module_key)});

    const gkey = try vm.gc().allocString(global_name);
    try vm.globals().set(TValue.fromString(gkey), result);
}

/// Inject `arg` table into VM globals
/// Called by launcher before execution, not by Moonquakes facade
pub fn injectArg(globals: *TableObject, gc: *GC, options: RunOptions) !void {
    const arg_table = try gc.allocTable();

    // arg[-n]..arg[-1] = CLI tokens before script
    if (options.pre_script_args.len > 0) {
        const n: i64 = @intCast(options.pre_script_args.len);
        for (options.pre_script_args, 0..) |tok, i| {
            const s = try gc.allocString(tok);
            try arg_table.set(.{ .integer = -n + @as(i64, @intCast(i)) }, TValue.fromString(s));
        }
    } else if (options.exec_name.len > 0) {
        // Compatibility fallback
        const exec_str = try gc.allocString(options.exec_name);
        try arg_table.set(.{ .integer = -1 }, TValue.fromString(exec_str));
    }

    // arg[0] = script name
    const script_str = try gc.allocString(options.script_name);
    try arg_table.set(.{ .integer = 0 }, TValue.fromString(script_str));

    // arg[1], arg[2], ... = script arguments
    for (options.args, 0..) |arg, i| {
        const arg_str = try gc.allocString(arg);
        try arg_table.set(.{ .integer = @as(i64, @intCast(i + 1)) }, TValue.fromString(arg_str));
    }

    // Set arg global
    const arg_key = try gc.allocString("arg");
    try globals.set(TValue.fromString(arg_key), TValue.fromTable(arg_table));
}

/// Full execution pipeline with options
/// Creates Runtime, VM, injects context, compiles, executes, returns owned result
pub fn run(allocator: std.mem.Allocator, source: []const u8, options: RunOptions) !OwnedReturnValue {
    var source_name_buf: ?[]u8 = null;
    defer if (source_name_buf) |buf| allocator.free(buf);

    const source_name: []const u8 = if (options.script_name.len > 0) blk: {
        if (options.script_name[0] == '@' or options.script_name[0] == '=') {
            break :blk options.script_name;
        }
        source_name_buf = try std.fmt.allocPrint(allocator, "@{s}", .{options.script_name});
        break :blk source_name_buf.?;
    } else "[string]";

    // Phase 1: Compile to RawProto (no GC needed)
    const compile_result = pipeline.compile(allocator, source, .{ .source_name = source_name });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(allocator);
            std.debug.print("[string]:{d}: {s}\n", .{ e.line, e.message });
            return error.CompileFailed;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(allocator, raw_proto);

    // Phase 2: Create Runtime (shared state) and VM (thread state)
    const rt = try Runtime.init(allocator);
    defer rt.deinit();

    const vm = try VM.init(rt);
    defer vm.deinit();
    vm.rt.warnings_enabled = options.warnings_enabled;

    // Phase 3: Inject execution context (arg table, etc.)
    try injectArg(vm.globals(), vm.gc(), options);
    try applyEnvironment(vm, allocator, options.ignore_environment);
    for (options.preload_modules) |module_spec| {
        try runPreloadModule(vm, module_spec);
    }
    for (options.exec_chunks) |chunk| {
        try executeInitChunk(vm, allocator, chunk, "=(command line)");
    }

    // Phase 4: Materialize constants (returns GC-managed ProtoObject)
    const proto = try pipeline.materialize(&raw_proto, vm.gc(), allocator);
    // No defer needed - ProtoObject is GC-managed

    // Phase 5: Execute
    var main_args = std.ArrayList(TValue){};
    defer main_args.deinit(allocator);
    const arg_key = try vm.gc().allocString("arg");
    if (vm.globals().get(TValue.fromString(arg_key))) |arg_val| {
        const arg_tbl = arg_val.asTable() orelse {
            std.debug.print("[string]:?: 'arg' is not a table\n", .{});
            return error.LuaException;
        };
        var i: i64 = 1;
        while (true) : (i += 1) {
            const v = arg_tbl.get(.{ .integer = i }) orelse break;
            if (v.isNil()) break;
            try main_args.append(allocator, v);
        }
    }

    const result = Mnemonics.executeWithArgs(vm, proto, main_args.items) catch |err| {
        if (err == error.LuaException) {
            printUnhandledLuaError(vm, options.exec_name);
        }
        return err;
    };

    // Convert to owned values before VM is destroyed
    return owned.toOwnedReturnValue(allocator, result);
}

/// Load file and execute with options
pub fn runFile(allocator: std.mem.Allocator, file_path: []const u8, options: RunOptions) !OwnedReturnValue {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try allocator.alloc(u8, file_size);
    defer allocator.free(source);

    _ = try file.readAll(source);

    // Use file_path as script_name if not provided
    var opts = options;
    if (opts.script_name.len == 0) {
        opts.script_name = file_path;
    }

    const chunk_source = stripInitialHashLine(stripUtf8Bom(source), true);
    return run(allocator, chunk_source, opts);
}
