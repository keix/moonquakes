const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const GC = @import("../runtime/gc/gc.zig").GC;
const object = @import("../runtime/gc/object.zig");
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;
const builtin = @import("../builtin/dispatch.zig");
const Mnemonics = @import("mnemonics.zig");
const ErrorHandler = @import("error.zig");

// CallInfo represents a function call in the call stack
pub const CallInfo = struct {
    // Function info
    func: *const Proto,
    closure: ?*ClosureObject, // closure for upvalue access (null for main chunk)

    // Execution state
    pc: [*]const Instruction,
    savedpc: ?[*]const Instruction, // saved pc for yielding

    // Stack frame
    base: u32,
    ret_base: u32, // Where to place return values in caller's frame

    // Call control
    nresults: i16, // expected number of results (-1 = multiple)
    previous: ?*CallInfo, // previous frame in the call stack

    /// Fetch next instruction and advance PC
    /// Encapsulates PC bounds checking as an invariant
    pub inline fn fetch(self: *CallInfo) !Instruction {
        try self.validatePC();
        const inst = self.pc[0];
        self.skip();

        return inst;
    }

    /// Skip next instruction (increment PC by 1)
    pub inline fn skip(self: *CallInfo) void {
        self.pc += 1;
    }

    /// Jump relatively from current PC position
    /// Handles both forward and backward jumps
    pub inline fn jumpRel(self: *CallInfo, offset: i32) !void {
        if (offset >= 0) {
            self.pc += @as(usize, @intCast(offset));
        } else {
            self.pc -= @as(usize, @intCast(-offset));
        }

        try self.validatePC();
    }

    /// Fetch next instruction expecting it to be EXTRAARG
    /// Used by instructions like LOADKX that consume 2-word opcodes
    pub inline fn fetchExtraArg(self: *CallInfo) !Instruction {
        const inst = try self.fetch();
        if (inst.getOpCode() != .EXTRAARG) {
            return error.UnknownOpcode;
        }
        return inst;
    }

    /// Validate PC is within function bounds (disabled in ReleaseFast)
    inline fn validatePC(self: *CallInfo) !void {
        if (std.debug.runtime_safety) {
            const pc_offset = @intFromPtr(self.pc) - @intFromPtr(self.func.code.ptr);
            const pc_index = pc_offset / @sizeOf(Instruction);
            if (pc_index >= self.func.code.len) {
                return error.PcOutOfRange;
            }
        }
    }
};

pub const VM = struct {
    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo, // Support up to 35 nested calls
    callstack_size: u8,
    globals: *TableObject,
    allocator: std.mem.Allocator,
    gc: GC, // Garbage collector (replaces arena)
    open_upvalues: ?*UpvalueObject, // Linked list of open upvalues (sorted by stack level)

    pub fn init(allocator: std.mem.Allocator) !VM {
        // Initialize GC first so we can allocate strings and tables
        var gc = GC.init(allocator);

        // Create globals table via GC
        const globals = try gc.allocTable();

        // Initialize global environment (needs GC for string allocation)
        try builtin.initGlobalEnvironment(globals, &gc);

        var vm = VM{
            .stack = undefined,
            .stack_last = 256 - 1,
            .top = 0,
            .base = 0,
            .ci = null,
            .base_ci = undefined,
            .callstack = undefined,
            .callstack_size = 0,
            .globals = globals,
            .allocator = allocator,
            .gc = gc,
            .open_upvalues = null,
        };
        for (&vm.stack) |*v| {
            v.* = .nil;
        }

        return vm;
    }

    pub fn deinit(self: *VM) void {
        // All tables are now GC-managed, so just clean up the GC
        // GC.deinit() will free all allocated objects (tables, strings, closures)
        self.gc.deinit();
    }

    /// Run garbage collection, marking all reachable objects from VM roots
    pub fn collectGarbage(self: *VM) void {
        const before = self.gc.bytes_allocated;

        // Mark phase: mark all roots

        // 1. Mark VM stack (active portion)
        self.gc.markStack(self.stack[0..self.top]);

        // 2. Mark closures from call frames (GC will mark proto.k via ClosureObject)
        //    For main chunk (no closure), mark proto.k directly
        if (self.ci) |ci| {
            if (ci.closure) |closure| {
                self.gc.mark(&closure.header);
            } else {
                // Main chunk has no closure - mark its constants directly
                self.gc.markConstants(ci.func.k);
            }
        }

        for (self.callstack[0..self.callstack_size]) |frame| {
            if (frame.closure) |closure| {
                self.gc.mark(&closure.header);
            } else {
                self.gc.markConstants(frame.func.k);
            }
        }

        // 3. Mark global environment
        self.gc.mark(&self.globals.header);

        // 4. Mark open upvalues
        var upval = self.open_upvalues;
        while (upval) |uv| {
            self.gc.mark(&uv.header);
            upval = uv.next_open;
        }

        // Sweep phase + threshold update
        self.gc.collect();

        // Debug output (disabled in ReleaseFast)
        if (@import("builtin").mode != .ReleaseFast) {
            std.log.info("GC: {} -> {} bytes, next at {}", .{ before, self.gc.bytes_allocated, self.gc.next_gc });
        }
    }

    /// Close all upvalues at or above the given stack level
    pub fn closeUpvalues(self: *VM, level: u32) void {
        while (self.open_upvalues) |uv| {
            // Check if this upvalue points to a stack slot at or above level
            const uv_level = (@intFromPtr(uv.location) - @intFromPtr(&self.stack[0])) / @sizeOf(TValue);
            if (uv_level < level) break;

            // Remove from open list and close
            self.open_upvalues = uv.next_open;
            uv.close();
        }
    }

    /// Get existing open upvalue for stack slot, or create a new one
    pub fn getOrCreateUpvalue(self: *VM, location: *TValue) !*UpvalueObject {
        // Search for existing open upvalue pointing to this location
        var prev: ?*UpvalueObject = null;
        var current = self.open_upvalues;

        while (current) |uv| {
            if (@intFromPtr(uv.location) == @intFromPtr(location)) {
                // Found existing upvalue
                return uv;
            }
            if (@intFromPtr(uv.location) < @intFromPtr(location)) {
                // Passed the insertion point (list is sorted by descending address)
                break;
            }
            prev = uv;
            current = uv.next_open;
        }

        // Create new upvalue
        const new_uv = try self.gc.allocUpvalue(location);

        // Insert into sorted list
        new_uv.next_open = current;
        if (prev) |p| {
            p.next_open = new_uv;
        } else {
            self.open_upvalues = new_uv;
        }

        return new_uv;
    }

    /// VM is just a bridge - dispatches to appropriate native function
    pub fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
        try builtin.invoke(id, self, func_reg, nargs, nresults);
    }

    /// Sugar Layer: Handle VM error with user-friendly reporting
    /// Translates internal VM errors to Lua error messages
    fn handleVMError(self: *VM, vm_error: anyerror) !void {
        // Check if this is a VM internal error that should be translated
        const vm_error_typed = switch (vm_error) {
            error.PcOutOfRange => ErrorHandler.VMError.PcOutOfRange,
            error.CallStackOverflow => ErrorHandler.VMError.CallStackOverflow,
            error.ArithmeticError => ErrorHandler.VMError.ArithmeticError,
            error.OrderComparisonError => ErrorHandler.VMError.OrderComparisonError,
            error.InvalidForLoopInit => ErrorHandler.VMError.InvalidForLoopInit,
            error.InvalidForLoopStep => ErrorHandler.VMError.InvalidForLoopStep,
            error.InvalidForLoopLimit => ErrorHandler.VMError.InvalidForLoopLimit,
            error.NotAFunction => ErrorHandler.VMError.NotAFunction,
            error.InvalidTableKey => ErrorHandler.VMError.InvalidTableKey,
            error.InvalidTableOperation => ErrorHandler.VMError.InvalidTableOperation,
            error.UnknownOpcode => ErrorHandler.VMError.UnknownOpcode,
            error.VariableReturnNotImplemented => ErrorHandler.VMError.VariableReturnNotImplemented,
            else => return vm_error, // Pass through non-VM errors
        };

        // Use Sugar Layer to translate and report the error
        const error_message = ErrorHandler.reportError(vm_error_typed, self.allocator, null) catch |err| switch (err) {
            error.OutOfMemory => "out of memory during error reporting",
            else => "unknown error occurred",
        };
        defer if (error_message.len > 0) self.allocator.free(error_message);

        // Print the user-friendly error message
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        stderr.print("{s}\n", .{error_message}) catch {};

        // Propagate the original error for proper control flow
        return vm_error;
    }

    pub const ArithOp = enum { add, sub, mul, div, idiv, mod, pow };
    pub const BitwiseOp = enum { band, bor, bxor };

    // Push a new call info onto the call stack
    pub fn pushCallInfo(self: *VM, func: *const Proto, closure: ?*ClosureObject, base: u32, ret_base: u32, nresults: i16) !*CallInfo {
        if (self.callstack_size >= self.callstack.len) {
            return error.CallStackOverflow;
        }

        // TODO: Move CallInfo creation into CallInfo.initCall().
        // Currently VM constructs call frames directly for clarity.
        // Revisit after CALL / TAILCALL / RETURN semantics are fully stabilized.

        const new_ci = &self.callstack[self.callstack_size];
        new_ci.* = CallInfo{
            .func = func,
            .closure = closure, // closure for upvalue access (null for main chunk)
            .pc = func.code.ptr,
            .savedpc = null,
            .base = base,
            .ret_base = ret_base,
            .nresults = nresults,
            .previous = self.ci,
        };

        self.callstack_size += 1;
        self.ci = new_ci;
        self.base = base;

        return new_ci;
    }

    // Pop a call info from the call stack
    pub fn popCallInfo(self: *VM) void {
        if (self.ci) |ci| {
            if (ci.previous) |prev| {
                self.ci = prev;
                self.base = prev.base;
                if (self.callstack_size > 0) {
                    self.callstack_size -= 1;
                }
            }
        }
    }

    pub fn arithBinary(self: *VM, inst: Instruction, comptime tag: ArithOp) !void {
        const a = inst.getA();
        const b = inst.getB();
        const c = inst.getC();
        const vb = &self.stack[self.base + b];
        const vc = &self.stack[self.base + c];

        // Try integer arithmetic first for add, sub, mul
        if (tag == .add or tag == .sub or tag == .mul) {
            if (vb.isInteger() and vc.isInteger()) {
                const ib = vb.integer;
                const ic = vc.integer;
                const res = switch (tag) {
                    .add => ib + ic,
                    .sub => ib - ic,
                    .mul => ib * ic,
                    else => unreachable,
                };
                self.stack[self.base + a] = .{ .integer = res };
                return;
            }
        }

        // Fall back to floating point
        const nb = vb.toNumber() orelse return error.ArithmeticError;
        const nc = vc.toNumber() orelse return error.ArithmeticError;

        // Check for division by zero
        if ((tag == .div or tag == .idiv or tag == .mod) and nc == 0) {
            return error.ArithmeticError;
        }

        const res = switch (tag) {
            .add => nb + nc,
            .sub => nb - nc,
            .mul => nb * nc,
            .div => nb / nc,
            .idiv => luaFloorDiv(nb, nc),
            .mod => luaMod(nb, nc),
            .pow => std.math.pow(f64, nb, nc),
        };

        self.stack[self.base + a] = .{ .number = res };
    }

    pub fn luaFloorDiv(a: f64, b: f64) f64 {
        return @floor(a / b);
    }

    pub fn luaMod(a: f64, b: f64) f64 {
        return a - luaFloorDiv(a, b) * b;
    }

    pub fn bitwiseBinary(self: *VM, inst: Instruction, comptime tag: BitwiseOp) !void {
        // Bitwise operations in Lua 5.3+ work only on integers
        // Floats with no fractional part can be converted to integers
        const a = inst.getA();
        const b = inst.getB();
        const c = inst.getC();
        const vb = &self.stack[self.base + b];
        const vc = &self.stack[self.base + c];

        // Helper to convert value to integer for bitwise ops
        const toInt = struct {
            fn convert(v: *const TValue) !i64 {
                if (v.isInteger()) {
                    return v.integer;
                } else if (v.toNumber()) |n| {
                    // Check if it's a whole number
                    if (@floor(n) == n) {
                        return @as(i64, @intFromFloat(n));
                    }
                }
                return error.ArithmeticError;
            }
        }.convert;

        const ib = try toInt(vb);
        const ic = try toInt(vc);

        const res = switch (tag) {
            .band => ib & ic,
            .bor => ib | ic,
            .bxor => ib ^ ic,
        };

        self.stack[self.base + a] = .{ .integer = res };
    }

    pub fn eqOp(a: TValue, b: TValue) bool {
        return a.eql(b);
    }

    pub fn ltOp(a: TValue, b: TValue) !bool {
        // Fast path: integer comparison
        if (a.isInteger() and b.isInteger()) {
            return a.integer < b.integer;
        }
        const na = a.toNumber();
        const nb = b.toNumber();
        if (na != null and nb != null) {
            // In Lua, any comparison with NaN returns false
            if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
                return false;
            }
            return na.? < nb.?;
        }
        // TODO: string comparison will be added when string type is implemented
        // Non-numeric types cannot be ordered
        return error.OrderComparisonError;
    }

    pub fn leOp(a: TValue, b: TValue) !bool {
        // Fast path: integer comparison
        if (a.isInteger() and b.isInteger()) {
            return a.integer <= b.integer;
        }
        const na = a.toNumber();
        const nb = b.toNumber();
        if (na != null and nb != null) {
            // In Lua, any comparison with NaN returns false
            if (std.math.isNan(na.?) or std.math.isNan(nb.?)) {
                return false;
            }
            return na.? <= nb.?;
        }
        // TODO: string comparison will be added when string type is implemented
        // Non-numeric types cannot be ordered
        return error.OrderComparisonError;
    }

    pub const ReturnValue = union(enum) {
        none,
        single: TValue,
        multiple: []TValue,
    };

    // TODO: Move CallInfo initialization to CallInfo.initMain().
    // This frame is a VM bootstrap (root frame), not a normal call frame.
    // Separate initialization when CallInfo responsibilities are clarified.
    fn setupMainFrame(self: *VM, proto: *const Proto) void {
        self.base_ci = CallInfo{
            .func = proto,
            .closure = null, // main chunk has no closure
            .pc = proto.code.ptr,
            .savedpc = null,
            .base = 0,
            .ret_base = 0,
            .nresults = -1,
            .previous = null,
        };
        self.ci = &self.base_ci;
        self.base = 0;
        self.top = proto.maxstacksize;
    }

    pub fn execute(self: *VM, proto: *const Proto) !ReturnValue {
        // Set VM reference in GC for automatic collection
        self.gc.setVM(self);

        self.setupMainFrame(proto);

        // Semantics frozen here.
        // Mnemonics.do() contains all opcode implementations.
        // Metamethod dispatch will be inserted at marked points.
        // Changing Mnemonics requires revisiting standard library and C API.
        while (true) {
            const ci = self.ci.?;
            const inst = try ci.fetch();

            switch (try Mnemonics.do(self, inst)) {
                .Continue => {},
                .LoopContinue => continue,
                .ReturnVM => |ret| return ret,
            }
        }
    }
};
