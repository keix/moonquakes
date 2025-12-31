const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Debug Library
/// Corresponds to Lua manual chapter "The Debug Library"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.10
/// debug.debug() - Enters interactive mode, reads and executes each string
pub fn nativeDebugDebug(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.debug
    // Interactive debugging mode
}

/// debug.gethook([thread]) - Returns current hook settings
pub fn nativeDebugGethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.gethook
    // Returns hook function, mask, and count
}

/// debug.getinfo([thread,] f [, what]) - Returns table with information about a function
pub fn nativeDebugGetinfo(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getinfo
    // Returns function information table
}

/// debug.getlocal([thread,] f, local) - Returns name and value of local variable
pub fn nativeDebugGetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getlocal
    // f can be function or stack level
}

/// debug.getmetatable(value) - Returns metatable of given value
pub fn nativeDebugGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getmetatable
    // Can get metatable of any type (unlike getmetatable())
}

/// debug.getregistry() - Returns the registry table
pub fn nativeDebugGetregistry(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getregistry
    // Returns global registry table
}

/// debug.getupvalue(f, up) - Returns name and value of upvalue up of function f
pub fn nativeDebugGetupvalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getupvalue
}

/// debug.getuservalue(u [, n]) - Returns the n-th user value associated with userdata u
pub fn nativeDebugGetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getuservalue
    // Works with userdata only
}

/// debug.sethook([thread,] hook, mask [, count]) - Sets given function as a hook
pub fn nativeDebugSethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.sethook
    // mask can contain 'c', 'r', 'l'
}

/// debug.setlocal([thread,] level, local, value) - Assigns value to local variable
pub fn nativeDebugSetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setlocal
    // Returns name of local variable or nil
}

/// debug.setmetatable(value, table) - Sets metatable for given value
pub fn nativeDebugSetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setmetatable
    // Can set metatable of any type (unlike setmetatable())
}

/// debug.setupvalue(f, up, value) - Assigns value to upvalue up of function f
pub fn nativeDebugSetupvalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setupvalue
    // Returns name of upvalue or nil
}

/// debug.setuservalue(udata, value [, n]) - Sets the n-th user value of userdata udata to value
pub fn nativeDebugSetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setuservalue
    // Returns udata
}

/// debug.traceback([thread,] [message [, level]]) - Returns a string with a traceback of the call stack
pub fn nativeDebugTraceback(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.traceback
    // Returns formatted call stack trace
}

/// debug.upvalueid(f, n) - Returns unique identifier for upvalue n of function f
pub fn nativeDebugUpvalueid(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.upvalueid
    // Returns unique identifier (light userdata)
}

/// debug.upvaluejoin(f1, n1, f2, n2) - Makes upvalue n1 of function f1 refer to upvalue n2 of function f2
pub fn nativeDebugUpvaluejoin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.upvaluejoin
    // Joins upvalue references
}
