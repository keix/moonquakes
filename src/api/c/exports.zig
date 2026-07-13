//! Moonquakes C API Exports
//!
//! Aggregated exports for the C interface.

pub const constants = @import("constants.zig");

const std = @import("std");
const mq = @import("moonquakes");

const VM = mq.VM;
const Runtime = mq.Runtime;
const TValue = mq.TValue;
const pipeline = mq.pipeline;
const call_mod = mq.call;
const error_state = mq.error_state;

pub const mq_CFunction = *const fn (?*mq_State) callconv(.c) c_int;

const State = struct {
    vm: *VM,
};

pub const mq_State = opaque {};

inline fn vmOf(state: ?*mq_State) ?*VM {
    const s = state orelse return null;
    const real: *State = @ptrCast(@alignCast(s));
    return real.vm;
}

/// Resolve a Lua-style 1-based index to an absolute stack slot.
/// Positive indices count up from the frame base (1 = base + 0).
/// Negative indices count down from `top` (-1 = top - 1).
/// Returns null for 0 or out-of-range indices.
fn absIndex(vm: *VM, idx: c_int) ?u32 {
    if (idx == 0) return null;
    const base_i: i64 = @intCast(vm.base);
    const top_i: i64 = @intCast(vm.top);
    const abs_i: i64 = if (idx > 0)
        base_i + @as(i64, idx) - 1
    else
        top_i + @as(i64, idx);
    if (abs_i < base_i or abs_i >= top_i) return null;
    return @intCast(abs_i);
}

pub export fn mq_version() [*:0]const u8 {
    return mq.version;
}

pub export fn mq_newstate() ?*mq_State {
    const allocator = std.heap.c_allocator;

    const rt = Runtime.init(allocator) catch return null;
    const vm = VM.init(rt) catch {
        rt.deinit();
        return null;
    };

    const state = allocator.create(State) catch {
        vm.deinit();
        rt.deinit();
        return null;
    };

    state.* = .{
        .vm = vm,
    };
    const opaque_state: *mq_State = @ptrCast(state);
    vm.c_state_opaque = opaque_state;
    return opaque_state;
}

pub export fn mq_close(state: ?*mq_State) void {
    const s = state orelse return;
    const real: *State = @ptrCast(@alignCast(s));
    const rt = real.vm.rt;

    real.vm.deinit();
    rt.deinit();

    std.heap.c_allocator.destroy(real);
}

/// Sub-command dispatch for garbage-collector control (matches Lua's
/// `lua_gc(L, what, ...)`). `data` is only consulted by sub-commands that
/// take an argument (`MQ_GCSTEP`, `MQ_GCSETPAUSE`, `MQ_GCSETSTEPMUL`); it is
/// ignored otherwise. Returns 0 for sub-commands without a return value,
/// the requested measurement for `MQ_GCCOUNT` / `MQ_GCCOUNTB`, the previous
/// running flag for `MQ_GCSTOP`, the previous tuning value for
/// `MQ_GCSETPAUSE` / `MQ_GCSETSTEPMUL`, the previous mode for
/// `MQ_GCGEN` / `MQ_GCINC`, and `-1` for unknown sub-commands.
pub export fn mq_gc(state: ?*mq_State, what: c_int, data: c_int) c_int {
    const vm = vmOf(state) orelse return -1;
    const gc = vm.gc();
    return switch (what) {
        constants.MQ_GCSTOP => @intFromBool(gc.stop()),
        constants.MQ_GCRESTART => blk: {
            gc.restart();
            break :blk 0;
        },
        constants.MQ_GCCOLLECT => blk: {
            vm.collectGarbage();
            break :blk 0;
        },
        constants.MQ_GCCOUNT => @intCast(gc.getCountKB()),
        constants.MQ_GCCOUNTB => @intCast(gc.getCountB()),
        constants.MQ_GCSTEP => blk: {
            const hint: usize = if (data > 0) @intCast(data) else 1;
            _ = gc.stepSized(hint);
            break :blk 0;
        },
        constants.MQ_GCSETPAUSE => blk: {
            const old = gc.pause;
            gc.pause = @intCast(data);
            break :blk @intCast(old);
        },
        constants.MQ_GCSETSTEPMUL => blk: {
            const old = gc.stepmul;
            gc.stepmul = @intCast(data);
            break :blk @intCast(old);
        },
        constants.MQ_GCISRUNNING => @intFromBool(gc.is_running),
        constants.MQ_GCGEN => blk: {
            const prev: c_int = switch (gc.mode) {
                .incremental => constants.MQ_GCINC,
                .generational => constants.MQ_GCGEN,
            };
            gc.mode = .generational;
            break :blk prev;
        },
        constants.MQ_GCINC => blk: {
            const prev: c_int = switch (gc.mode) {
                .incremental => constants.MQ_GCINC,
                .generational => constants.MQ_GCGEN,
            };
            gc.mode = .incremental;
            break :blk prev;
        },
        else => -1,
    };
}

pub export fn mq_gettop(state: ?*mq_State) c_int {
    const s = state orelse return 0;
    const real: *State = @ptrCast(@alignCast(s));
    return @intCast(real.vm.top - real.vm.base);
}

pub export fn mq_settop(state: ?*mq_State, idx: c_int) void {
    const s = state orelse return;
    const real: *State = @ptrCast(@alignCast(s));
    const vm = real.vm;

    const base_i: i32 = @intCast(vm.base);
    const top_i: i32 = @intCast(vm.top);
    var new_top_i: i32 = if (idx >= 0)
        base_i + idx
    else
        top_i + idx + 1;

    if (new_top_i < base_i) new_top_i = base_i;
    const max_top_i: i32 = @intCast(vm.stack.len);
    if (new_top_i > max_top_i) new_top_i = max_top_i;

    const new_top: u32 = @intCast(new_top_i);
    if (new_top > vm.top) {
        var i: u32 = vm.top;
        while (i < new_top) : (i += 1) {
            vm.stack[i] = .nil;
        }
    }
    vm.top = new_top;
}

// ----------------------------------------------------------------------------
// Type inspection
// ----------------------------------------------------------------------------

fn tvalueTypeTag(v: TValue) c_int {
    return switch (v.kind()) {
        .nil => constants.MQ_TNIL,
        .boolean => constants.MQ_TBOOLEAN,
        .integer, .number => constants.MQ_TNUMBER,
        .object => switch ((v).asObjectPtr().type) {
            .string => constants.MQ_TSTRING,
            .table => constants.MQ_TTABLE,
            .closure, .native_closure, .c_closure => constants.MQ_TFUNCTION,
            .userdata, .file, .dynamic_library => constants.MQ_TUSERDATA,
            .thread => constants.MQ_TTHREAD,
            .proto, .upvalue => constants.MQ_TNONE,
        },
    };
}

pub export fn mq_type(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return constants.MQ_TNONE;
    const abs = absIndex(vm, idx) orelse return constants.MQ_TNONE;
    return tvalueTypeTag(vm.stack[abs]);
}

pub export fn mq_typename(state: ?*mq_State, t: c_int) [*:0]const u8 {
    _ = state;
    return switch (t) {
        constants.MQ_TNIL => "nil",
        constants.MQ_TBOOLEAN => "boolean",
        constants.MQ_TLIGHTUSERDATA => "userdata",
        constants.MQ_TNUMBER => "number",
        constants.MQ_TSTRING => "string",
        constants.MQ_TTABLE => "table",
        constants.MQ_TFUNCTION => "function",
        constants.MQ_TUSERDATA => "userdata",
        constants.MQ_TTHREAD => "thread",
        else => "no value",
    };
}

pub export fn mq_isnil(state: ?*mq_State, idx: c_int) c_int {
    return @intFromBool(mq_type(state, idx) == constants.MQ_TNIL);
}

pub export fn mq_isnone(state: ?*mq_State, idx: c_int) c_int {
    return @intFromBool(mq_type(state, idx) == constants.MQ_TNONE);
}

pub export fn mq_isnoneornil(state: ?*mq_State, idx: c_int) c_int {
    const t = mq_type(state, idx);
    return @intFromBool(t == constants.MQ_TNONE or t == constants.MQ_TNIL);
}

pub export fn mq_isboolean(state: ?*mq_State, idx: c_int) c_int {
    return @intFromBool(mq_type(state, idx) == constants.MQ_TBOOLEAN);
}

pub export fn mq_istable(state: ?*mq_State, idx: c_int) c_int {
    return @intFromBool(mq_type(state, idx) == constants.MQ_TTABLE);
}

pub export fn mq_isfunction(state: ?*mq_State, idx: c_int) c_int {
    return @intFromBool(mq_type(state, idx) == constants.MQ_TFUNCTION);
}

/// True when the value is a number, or a string convertible to a number
/// (matches Lua's `lua_isnumber`).
pub export fn mq_isnumber(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return 0;
    const abs = absIndex(vm, idx) orelse return 0;
    return @intFromBool(vm.stack[abs].toNumber() != null);
}

/// True only when the value is an integer subtype (no string coercion,
/// no float promotion).
pub export fn mq_isinteger(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return 0;
    const abs = absIndex(vm, idx) orelse return 0;
    return @intFromBool(vm.stack[abs].isInteger());
}

/// True when the value is a string, or any number (matches Lua's
/// `lua_isstring`: numbers are accepted because they coerce to strings).
pub export fn mq_isstring(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return 0;
    const abs = absIndex(vm, idx) orelse return 0;
    return switch (vm.stack[abs].kind()) {
        .integer, .number => 1,
        .object => @intFromBool(vm.stack[abs].asObjectPtr().type == .string),
        else => 0,
    };
}

// ----------------------------------------------------------------------------
// Push
// ----------------------------------------------------------------------------

/// Append a TValue to the VM stack. Silently no-ops when the fixed stack is
/// full; callers should ensure capacity beforehand.
fn pushTValue(vm: *VM, value: TValue) void {
    if (vm.top >= vm.stack.len) return;
    vm.stack[vm.top] = value;
    vm.top += 1;
}

pub export fn mq_pushnil(state: ?*mq_State) void {
    const vm = vmOf(state) orelse return;
    pushTValue(vm, .nil);
}

pub export fn mq_pushboolean(state: ?*mq_State, b: c_int) void {
    const vm = vmOf(state) orelse return;
    pushTValue(vm, TValue.fromBool(b != 0));
}

pub export fn mq_pushinteger(state: ?*mq_State, n: i64) void {
    const vm = vmOf(state) orelse return;
    pushTValue(vm, TValue.fromInt(n));
}

pub export fn mq_pushnumber(state: ?*mq_State, n: f64) void {
    const vm = vmOf(state) orelse return;
    pushTValue(vm, TValue.fromFloat(n));
}

/// Push a string of explicit length. Returns a **borrowed** pointer to the
/// interned bytes — not NUL-terminated, valid only for `len` bytes, and only
/// while the underlying value remains alive. Returns null when the state is
/// invalid, the source is null with non-zero length, or allocation fails.
pub export fn mq_pushlstring(
    state: ?*mq_State,
    s: ?[*]const u8,
    len: usize,
) ?[*]const u8 {
    const vm = vmOf(state) orelse return null;
    const slice: []const u8 = if (len == 0) "" else blk: {
        const p = s orelse return null;
        break :blk p[0..len];
    };
    const str_obj = vm.gc().allocString(slice) catch return null;
    pushTValue(vm, TValue.fromString(str_obj));
    return str_obj.data();
}

/// Push a NUL-terminated C string. A null pointer pushes nil and returns null.
/// The returned pointer is a borrowed view into the interned bytes; see
/// `mq_pushlstring` for lifetime rules.
pub export fn mq_pushstring(state: ?*mq_State, s: ?[*:0]const u8) ?[*]const u8 {
    const vm = vmOf(state) orelse return null;
    const cstr = s orelse {
        pushTValue(vm, .nil);
        return null;
    };
    const slice = std.mem.span(cstr);
    const str_obj = vm.gc().allocString(slice) catch return null;
    pushTValue(vm, TValue.fromString(str_obj));
    return str_obj.data();
}

/// Push a native callable wrapping the external C function `fn_ptr`.
///
/// The pushed value behaves as a Lua function: it can be assigned, stored in
/// tables, and invoked via `mq_pcall` or from Lua code. When called, the
/// callee sees a fresh stack frame where index 1 is the first argument and
/// `mq_gettop(L) == nargs`. It pushes its results and returns the result
/// count. A negative return value signals an error; the dispatcher takes the
/// top-of-stack value (or a synthesized message when the stack is empty) as
/// the error value.
///
/// This v1 entry point has **no upvalue support**. Use the future
/// `mq_pushcclosure` for that. Calls from a C function back into a yieldable
/// path are unsupported.
///
/// No-op when the state is invalid, `fn_ptr` is null, or allocation fails.
pub export fn mq_pushcfunction(state: ?*mq_State, fn_ptr: ?mq_CFunction) void {
    const vm = vmOf(state) orelse return;
    const fp = fn_ptr orelse return;
    const cc = vm.gc().allocCClosure(@ptrCast(fp), null) catch return;
    pushTValue(vm, TValue.fromCClosure(cc));
}

/// Push a copy of the value at `idx`. No-op when the index is invalid.
pub export fn mq_pushvalue(state: ?*mq_State, idx: c_int) void {
    const vm = vmOf(state) orelse return;
    const abs = absIndex(vm, idx) orelse return;
    pushTValue(vm, vm.stack[abs]);
}

// ----------------------------------------------------------------------------
// Conversion (to*)
// ----------------------------------------------------------------------------

pub export fn mq_toboolean(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return 0;
    const abs = absIndex(vm, idx) orelse return 0;
    return @intFromBool(vm.stack[abs].toBoolean());
}

pub export fn mq_tointegerx(state: ?*mq_State, idx: c_int, isnum: ?*c_int) i64 {
    const vm = vmOf(state) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const abs = absIndex(vm, idx) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (vm.stack[abs].toInteger()) |n| {
        if (isnum) |p| p.* = 1;
        return n;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

pub export fn mq_tointeger(state: ?*mq_State, idx: c_int) i64 {
    return mq_tointegerx(state, idx, null);
}

pub export fn mq_tonumberx(state: ?*mq_State, idx: c_int, isnum: ?*c_int) f64 {
    const vm = vmOf(state) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    const abs = absIndex(vm, idx) orelse {
        if (isnum) |p| p.* = 0;
        return 0;
    };
    if (vm.stack[abs].toNumber()) |n| {
        if (isnum) |p| p.* = 1;
        return n;
    }
    if (isnum) |p| p.* = 0;
    return 0;
}

pub export fn mq_tonumber(state: ?*mq_State, idx: c_int) f64 {
    return mq_tonumberx(state, idx, null);
}

/// Format a float for Lua-style tostring: keep "N.0" for integral finite
/// values so the result remains distinguishable from an integer.
fn formatLuaFloat(buf: []u8, n: f64) []const u8 {
    const rendered = std.fmt.bufPrint(buf, "{d}", .{n}) catch return buf[0..0];
    if (std.math.isFinite(n) and
        std.mem.indexOfScalar(u8, rendered, '.') == null and
        std.mem.indexOfAny(u8, rendered, "eE") == null and
        rendered.len + 2 <= buf.len)
    {
        buf[rendered.len] = '.';
        buf[rendered.len + 1] = '0';
        return buf[0 .. rendered.len + 2];
    }
    return rendered;
}

/// Length-less compat shim for `mq_tolstring(L, idx, NULL)`. The return value
/// is a **borrowed byte view**, not a Lua-style NUL-terminated C string —
/// Moonquakes' GC strings are not NUL-terminated, so passing the result
/// directly to `printf("%s", ...)` is undefined unless the caller already
/// knows the string is NUL-followed by chance. Prefer `mq_tolstring` with an
/// explicit `len` for any actual use; `mq_tostring` exists only to satisfy
/// the Lua-shaped name in `api.md`.
pub export fn mq_tostring(state: ?*mq_State, idx: c_int) ?[*]const u8 {
    return mq_tolstring(state, idx, null);
}

/// Borrow the value at `idx` as a byte view. Strings are returned directly;
/// numbers are converted and the stack slot is rewritten in place (matching
/// `lua_tolstring`). Other types yield null.
///
/// The returned pointer is **borrowed** into GC-managed inline data:
/// - Read at most `*len` bytes; there is no trailing NUL.
/// - Valid only while the underlying value remains alive on the stack/globals
///   and the GC has not run a sweep that reclaims it.
///
/// `len` must be non-null when the caller plans to read the bytes. Passing
/// null is supported for "is this convertible to a string?" probes only.
pub export fn mq_tolstring(state: ?*mq_State, idx: c_int, len: ?*usize) ?[*]const u8 {
    const vm = vmOf(state) orelse return null;
    const abs = absIndex(vm, idx) orelse return null;
    const slot = &vm.stack[abs];

    if (slot.asString()) |s| {
        if (len) |p| p.* = s.len;
        return s.data();
    }

    var buf: [64]u8 = undefined;
    const rendered: []const u8 = switch (slot.*.kind()) {
        .integer => std.fmt.bufPrint(&buf, "{d}", .{slot.*.asInt()}) catch return null,
        .number => formatLuaFloat(&buf, slot.*.asFloat()),
        else => return null,
    };
    const str_obj = vm.gc().allocString(rendered) catch return null;
    slot.* = TValue.fromString(str_obj);
    if (len) |p| p.* = str_obj.len;
    return str_obj.data();
}

// ----------------------------------------------------------------------------
// Load (drain reader callback, compile, push as closure)
// ----------------------------------------------------------------------------

/// Reader callback signature: called repeatedly until it returns null or
/// writes `0` to `*size`. The returned pointer must stay valid until the
/// next reader call (the loader copies the chunk before invoking the reader
/// again).
pub const mq_Reader = ?*const fn (
    state: ?*mq_State,
    data: ?*anyopaque,
    size: *usize,
) callconv(.c) ?[*]const u8;

/// Load a Lua chunk by draining `reader` to a byte buffer, compiling it,
/// and pushing the resulting closure on the stack.
///
/// On `MQ_OK` the closure is at the top; on `MQ_ERRSYNTAX` the top holds a
/// `<chunkname>:line: message` string; on `MQ_ERRMEM` no value is guaranteed.
/// `chunkname` defaults to `"(load)"` when null. `mode` is currently ignored
/// (text mode only); a future bytecode loader will consult it.
pub export fn mq_load(
    state: ?*mq_State,
    reader: mq_Reader,
    data: ?*anyopaque,
    chunkname: ?[*:0]const u8,
    mode: ?[*:0]const u8,
) c_int {
    _ = mode;
    const vm = vmOf(state) orelse return constants.MQ_ERRRUN;
    const cb = reader orelse return constants.MQ_ERRSYNTAX;
    const allocator = vm.gc().allocator;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    while (true) {
        var chunk_size: usize = 0;
        const chunk_ptr = cb(state, data, &chunk_size) orelse break;
        if (chunk_size == 0) break;
        buf.appendSlice(allocator, chunk_ptr[0..chunk_size]) catch return constants.MQ_ERRMEM;
    }

    const name_slice: []const u8 = if (chunkname) |c| std.mem.span(c) else "=(load)";

    const compile_result = pipeline.compile(allocator, buf.items, .{ .source_name = name_slice });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(allocator);
            const formatted = std.fmt.allocPrint(
                allocator,
                "{s}:{d}: {s}",
                .{ trimChunkPrefix(name_slice), e.line, e.message },
            ) catch {
                pushTValue(vm, .nil);
                return constants.MQ_ERRMEM;
            };
            defer allocator.free(formatted);
            const msg_obj = vm.gc().allocString(formatted) catch {
                pushTValue(vm, .nil);
                return constants.MQ_ERRMEM;
            };
            pushTValue(vm, TValue.fromString(msg_obj));
            return constants.MQ_ERRSYNTAX;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(allocator, raw_proto);

    const proto = pipeline.materialize(&raw_proto, vm.gc(), allocator) catch return constants.MQ_ERRMEM;
    const closure = vm.gc().allocClosure(proto) catch return constants.MQ_ERRMEM;
    pushTValue(vm, TValue.fromClosure(closure));
    return constants.MQ_OK;
}

/// Strip the "=" / "@" sigil that pipeline source names carry so error
/// messages read naturally.
fn trimChunkPrefix(name: []const u8) []const u8 {
    if (name.len == 0) return "[string]";
    if (name[0] == '=' or name[0] == '@') return name[1..];
    return name;
}

// ----------------------------------------------------------------------------
// Protected call
// ----------------------------------------------------------------------------

const PCALL_MAX_RESULTS: usize = 256;

/// Protected call. Pops the function and `nargs` arguments from the top of
/// the stack, calls the function, and pushes `nresults` values. Returns one
/// of the `MQ_*` status codes; on error a single error value is pushed in
/// place of the results.
///
/// `msgh` is currently ignored: errors propagate as raised values without a
/// user-supplied message handler.
pub export fn mq_pcall(
    state: ?*mq_State,
    nargs: c_int,
    nresults: c_int,
    msgh: c_int,
) c_int {
    _ = msgh;
    const vm = vmOf(state) orelse return constants.MQ_ERRRUN;
    if (nargs < 0) return constants.MQ_ERRRUN;
    const n: u32 = @intCast(nargs);
    const frame_size = vm.top - vm.base;
    if (frame_size < n + 1) return constants.MQ_ERRRUN;

    const func_idx = vm.top - n - 1;
    const func = vm.stack[func_idx];
    const args = vm.stack[func_idx + 1 .. vm.top];

    if (nresults == 0) {
        _ = call_mod.callValueSafe(vm, func, args) catch |err| {
            return finishPCallError(vm, func_idx, err);
        };
        vm.top = func_idx;
        return constants.MQ_OK;
    }

    if (nresults < 0) return constants.MQ_ERRRUN; // MQ_MULTRET TODO
    const want: usize = @intCast(nresults);
    if (want > PCALL_MAX_RESULTS) return constants.MQ_ERRRUN;

    var out_buf: [PCALL_MAX_RESULTS]TValue = undefined;
    const out = out_buf[0..want];
    call_mod.callValueFixed(vm, func, args, .{ .out = out }) catch |err| {
        return finishPCallError(vm, func_idx, err);
    };

    vm.top = func_idx;
    for (out) |v| pushTValue(vm, v);
    return constants.MQ_OK;
}

/// Drop the func/args window and replace it with a single error value, then
/// translate the Zig error into an `MQ_*` status code.
fn finishPCallError(vm: *VM, func_idx: u32, err: anyerror) c_int {
    vm.top = func_idx;
    const raised = error_state.takeRaisedValue(vm);
    if (raised.isNil()) {
        const synth = vm.gc().allocString(@errorName(err)) catch {
            pushTValue(vm, .nil);
            return mqStatusFromError(err);
        };
        pushTValue(vm, TValue.fromString(synth));
    } else {
        pushTValue(vm, raised);
    }
    return mqStatusFromError(err);
}

fn mqStatusFromError(err: anyerror) c_int {
    return switch (err) {
        error.LuaException => constants.MQ_ERRRUN,
        error.OutOfMemory => constants.MQ_ERRMEM,
        else => constants.MQ_ERRRUN,
    };
}

// ----------------------------------------------------------------------------
// Tables
// ----------------------------------------------------------------------------

/// Create a new empty table and push it onto the stack. No-op when the state
/// is invalid or allocation fails (in which case nothing is pushed).
pub export fn mq_newtable(state: ?*mq_State) void {
    const vm = vmOf(state) orelse return;
    const tbl = vm.gc().allocTable() catch return;
    pushTValue(vm, TValue.fromTable(tbl));
}

/// Push `t[n]` for the table at `idx` and return the pushed value's type tag.
/// Missing keys, invalid indices, and non-table targets push nil.
pub export fn mq_geti(state: ?*mq_State, idx: c_int, n: i64) c_int {
    const vm = vmOf(state) orelse return constants.MQ_TNONE;
    const abs = absIndex(vm, idx) orelse {
        pushTValue(vm, .nil);
        return constants.MQ_TNIL;
    };
    const tbl = vm.stack[abs].asTable() orelse {
        pushTValue(vm, .nil);
        return constants.MQ_TNIL;
    };
    const v = tbl.get(TValue.fromInt(n)) orelse TValue.nil;
    pushTValue(vm, v);
    return tvalueTypeTag(v);
}

/// Do `t[k] = v`, where `t` is the table at `idx`, `k` is the NUL-terminated
/// string `name`, and `v` is the value on top of the stack. Pops `v` on
/// success. No-op when the state is invalid, the stack is empty, `name` is
/// null, the slot at `idx` is not a table, or allocation fails; in those
/// error paths the value is left on the stack so the caller can recover it.
pub export fn mq_setfield(state: ?*mq_State, idx: c_int, name: ?[*:0]const u8) void {
    const vm = vmOf(state) orelse return;
    const cstr = name orelse return;
    if (vm.top <= vm.base) return;
    const abs = absIndex(vm, idx) orelse return;
    const tbl = vm.stack[abs].asTable() orelse return;
    const slice = std.mem.span(cstr);
    const key_obj = vm.gc().allocString(slice) catch return;
    const top_val = vm.stack[vm.top - 1];
    vm.gc().tableSet(tbl, TValue.fromString(key_obj), top_val) catch return;
    vm.top -= 1;
}

/// Do `t[n] = v`, where `t` is the table at `idx`, `n` is an integer key, and
/// `v` is the value on top of the stack. Pops `v` on success. Mirrors
/// `mq_setfield`'s failure behavior: invalid state, empty stack, non-table
/// target, or allocation failure leaves the value on the stack.
pub export fn mq_seti(state: ?*mq_State, idx: c_int, n: i64) void {
    const vm = vmOf(state) orelse return;
    if (vm.top <= vm.base) return;
    const abs = absIndex(vm, idx) orelse return;
    const tbl = vm.stack[abs].asTable() orelse return;
    const top_val = vm.stack[vm.top - 1];
    vm.gc().tableSet(tbl, TValue.fromInt(n), top_val) catch return;
    vm.top -= 1;
}

/// Push the length of the value at `idx` and return the pushed type tag.
/// Currently supports strings and tables directly. Unsupported values push nil.
pub export fn mq_len(state: ?*mq_State, idx: c_int) c_int {
    const vm = vmOf(state) orelse return constants.MQ_TNONE;
    const abs = absIndex(vm, idx) orelse {
        pushTValue(vm, .nil);
        return constants.MQ_TNIL;
    };
    const v = vm.stack[abs];
    const len: i64 = if (v.asString()) |str|
        @intCast(str.len)
    else if (v.asTable()) |tbl|
        tbl.rawLen()
    else {
        pushTValue(vm, .nil);
        return constants.MQ_TNIL;
    };
    pushTValue(vm, TValue.fromInt(len));
    return constants.MQ_TNUMBER;
}

// ----------------------------------------------------------------------------
// Globals
// ----------------------------------------------------------------------------

/// Push the value of the named global onto the stack and return its type tag.
/// Pushes nil and returns `MQ_TNIL` when the key is absent.
pub export fn mq_getglobal(state: ?*mq_State, name: ?[*:0]const u8) c_int {
    const vm = vmOf(state) orelse return constants.MQ_TNONE;
    const cstr = name orelse return constants.MQ_TNONE;
    const slice = std.mem.span(cstr);
    const key_obj = vm.gc().allocString(slice) catch return constants.MQ_TNONE;
    const v = vm.globals().get(TValue.fromString(key_obj)) orelse TValue.nil;
    pushTValue(vm, v);
    return tvalueTypeTag(v);
}

/// Pop the top of the stack and store it in the named global.
pub export fn mq_setglobal(state: ?*mq_State, name: ?[*:0]const u8) void {
    const vm = vmOf(state) orelse return;
    const cstr = name orelse return;
    if (vm.top <= vm.base) return;
    const slice = std.mem.span(cstr);
    const key_obj = vm.gc().allocString(slice) catch return;
    const top_val = vm.stack[vm.top - 1];
    vm.gc().tableSet(vm.globals(), TValue.fromString(key_obj), top_val) catch return;
    vm.top -= 1;
}
