const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const CallInfo = @import("../vm/vm.zig").CallInfo;
const Proto = @import("../core/proto.zig").Proto;
const TValue = @import("../core/value.zig").TValue;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const OpCode = @import("../compiler/opcodes.zig").OpCode;
const test_utils = @import("test_utils.zig");

// Temporary extension to TValue for testing function calls
// In a real implementation, this would be part of TValue
pub const TValueExt = union(enum) {
    nil: void,
    boolean: bool,
    integer: i64,
    number: f64,
    function: *const Proto,

    pub fn fromTValue(val: TValue) TValueExt {
        return switch (val) {
            .nil => .nil,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .number => |n| .{ .number = n },
        };
    }

    pub fn toTValue(self: TValueExt) ?TValue {
        return switch (self) {
            .nil => .nil,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .number => |n| .{ .number = n },
            .function => null, // Cannot convert function to current TValue
        };
    }
};

// Function mapping for testing
pub const FunctionMapping = struct {
    slot: u8,
    func: *const Proto,
};

// Extended VM for testing function calls
pub const VMExt = struct {
    base_vm: VM,
    ext_stack: [256]TValueExt,

    pub fn init() VMExt {
        var vm_ext = VMExt{
            .base_vm = VM.init(std.testing.allocator) catch unreachable,
            .ext_stack = undefined,
        };
        for (&vm_ext.ext_stack) |*v| {
            v.* = .nil;
        }
        return vm_ext;
    }

    pub fn executeWithFunctions(self: *VMExt, proto: *const Proto, functions: []const FunctionMapping) !VM.ReturnValue {
        // Set up function values in extended stack globally
        // In a real implementation, functions would be stored as closures or in a global table
        for (functions) |f| {
            // Store function in all potential slots to simulate global availability
            var base: u32 = 0;
            while (base < 256 - 10) : (base += 10) {
                self.ext_stack[base + f.slot] = .{ .function = f.func };
            }
        }

        // Set up initial call frame
        self.base_vm.base_ci = CallInfo{
            .func = proto,
            .pc = proto.code.ptr,
            .base = 0,
            .savedpc = null,
            .nresults = -1,
            .previous = null,
        };
        self.base_vm.ci = &self.base_vm.base_ci;
        self.base_vm.base = 0;
        self.base_vm.top = proto.maxstacksize;

        return self.executeLoop();
    }

    fn executeLoop(self: *VMExt) !VM.ReturnValue {
        while (true) {
            var ci = self.base_vm.ci.?;
            const inst = ci.pc[0];
            ci.pc += 1;

            const op = inst.getOpCode();
            const a = inst.getA();

            switch (op) {
                .MOVE => {
                    const b = inst.getB();
                    self.base_vm.stack[self.base_vm.base + a] = self.base_vm.stack[self.base_vm.base + b];
                    self.ext_stack[self.base_vm.base + a] = self.ext_stack[self.base_vm.base + b];
                },
                .LOADK => {
                    const bx = inst.getBx();
                    self.base_vm.stack[self.base_vm.base + a] = ci.func.k[bx];
                    self.ext_stack[self.base_vm.base + a] = TValueExt.fromTValue(ci.func.k[bx]);
                },
                .ADD => {
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.base_vm.stack[self.base_vm.base + b];
                    const vc = &self.base_vm.stack[self.base_vm.base + c];

                    if (vb.isInteger() and vc.isInteger()) {
                        self.base_vm.stack[self.base_vm.base + a] = .{ .integer = vb.integer + vc.integer };
                        self.ext_stack[self.base_vm.base + a] = .{ .integer = vb.integer + vc.integer };
                    } else {
                        const nb = vb.toNumber() orelse return error.ArithmeticError;
                        const nc = vc.toNumber() orelse return error.ArithmeticError;
                        self.base_vm.stack[self.base_vm.base + a] = .{ .number = nb + nc };
                        self.ext_stack[self.base_vm.base + a] = .{ .number = nb + nc };
                    }
                },
                .CALL => {
                    // CALL A B C: R(A),...,R(A+C-2) := R(A)(R(A+1),...,R(A+B-1))
                    const b = inst.getB();
                    const c = inst.getC();

                    // Debug output
                    // std.debug.print("CALL: a={}, b={}, c={}, base={}\n", .{ a, b, c, self.base_vm.base });

                    // Get the function from extended stack
                    const func_slot = &self.ext_stack[self.base_vm.base + a];
                    if (func_slot.* != .function) {
                        // std.debug.print("Not a function at slot {}: {}\n", .{ self.base_vm.base + a, func_slot.* });
                        return error.NotAFunction;
                    }
                    const func = func_slot.function;

                    // Calculate number of arguments
                    const nargs = if (b > 0) b - 1 else return error.UnsupportedVarargCall;

                    // Calculate expected results
                    const nresults: i16 = if (c > 0) @as(i16, @intCast(c - 1)) else -1;

                    // New base for called function
                    const new_base = self.base_vm.base + a;

                    // Move arguments to correct positions
                    if (nargs > 0) {
                        var i: u8 = 0;
                        while (i < nargs) : (i += 1) {
                            self.base_vm.stack[new_base + i] = self.base_vm.stack[new_base + 1 + i];
                            self.ext_stack[new_base + i] = self.ext_stack[new_base + 1 + i];
                        }
                    }

                    // Push new call info
                    _ = try self.base_vm.pushCallInfo(func, new_base, new_base, nresults);
                },
                .RETURN => {
                    const b = inst.getB();

                    // Handle returns from nested calls
                    if (self.base_vm.ci.?.previous != null) {
                        // We're returning from a nested call
                        const returning_ci = self.base_vm.ci.?;
                        const nresults = returning_ci.nresults;
                        const calling_base = returning_ci.base;

                        // Pop the call info
                        self.base_vm.popCallInfo();

                        // Now handle copying results back
                        if (b == 1) {
                            // No return values
                            if (nresults > 0) {
                                var i: u16 = 0;
                                while (i < nresults) : (i += 1) {
                                    self.base_vm.stack[calling_base + i] = .nil;
                                    self.ext_stack[calling_base + i] = .nil;
                                }
                            }
                        } else if (b > 1) {
                            // Return b-1 values starting from R[A]
                            const ret_count = b - 1;

                            // Copy return values
                            if (nresults < 0) {
                                // Multiple results expected
                                var i: u16 = 0;
                                while (i < ret_count) : (i += 1) {
                                    self.base_vm.stack[calling_base + i] = self.base_vm.stack[returning_ci.base + a + i];
                                    self.ext_stack[calling_base + i] = self.ext_stack[returning_ci.base + a + i];
                                }
                                self.base_vm.top = calling_base + ret_count;
                            } else {
                                // Fixed number of results
                                var i: u16 = 0;
                                while (i < nresults) : (i += 1) {
                                    if (i < ret_count) {
                                        self.base_vm.stack[calling_base + i] = self.base_vm.stack[returning_ci.base + a + i];
                                        self.ext_stack[calling_base + i] = self.ext_stack[returning_ci.base + a + i];
                                    } else {
                                        self.base_vm.stack[calling_base + i] = .nil;
                                        self.ext_stack[calling_base + i] = .nil;
                                    }
                                }
                            }
                        }

                        // Continue execution in the calling function
                        continue;
                    }

                    // This is a return from the main function
                    if (b == 0) {
                        return .none;
                    } else if (b == 1) {
                        return .none;
                    } else if (b == 2) {
                        return .{ .single = self.base_vm.stack[self.base_vm.base + a] };
                    } else {
                        const count = b - 1;
                        const values = self.base_vm.stack[self.base_vm.base + a .. self.base_vm.base + a + count];
                        return .{ .multiple = values };
                    }
                },
                .LEI => {
                    // LEI A sB k: if ((R[A] <= sB) ~= k) then pc++
                    const sb = inst.getB();
                    const k = inst.getk();
                    const va = &self.base_vm.stack[self.base_vm.base + a];

                    const n = va.toNumber() orelse return error.OrderComparisonError;
                    const is_true = n <= @as(f64, @floatFromInt(@as(i8, @bitCast(sb))));

                    if (is_true != k) {
                        ci.pc += 1;
                    }
                },
                .JMP => {
                    const sj = inst.getsJ();
                    if (sj >= 0) {
                        ci.pc += @as(usize, @intCast(sj));
                    } else {
                        ci.pc -= @as(usize, @intCast(-sj));
                    }
                },
                else => {
                    // For other opcodes, delegate to the base VM's implementation
                    // This is a simplified approach for testing
                    return error.UnknownOpcode;
                },
            }
        }
    }
};

test "function call with single argument and return" {
    // Define the add function: function(a) return a + 10 end
    const add_constants = [_]TValue{
        .{ .integer = 10 },
    };
    const add_code = [_]Instruction{
        Instruction.initABx(.LOADK, 1, 0), // R[1] = 10
        Instruction.initABC(.ADD, 0, 0, 1), // R[0] = R[0] + R[1]
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const add_proto = Proto{
        .k = &add_constants,
        .code = &add_code,
        .numparams = 1,
        .is_vararg = false,
        .maxstacksize = 2,
    };

    // Define the main function: local x = 5; return add(x)
    const main_constants = [_]TValue{
        .{ .integer = 5 },
    };
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = 5
        Instruction.initABC(.MOVE, 2, 0, 0), // R[2] = R[0] (first argument)
        // R[1] should contain the add function
        Instruction.initABC(.CALL, 1, 2, 2), // R[1] = R[1](R[2]), expect 1 result
        Instruction.initABC(.RETURN, 1, 2, 0), // return R[1]
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    var vm_ext = VMExt.init();

    // Set up function in slot 1
    const functions = [_]FunctionMapping{
        .{ .slot = 1, .func = &add_proto },
    };

    const result = try vm_ext.executeWithFunctions(&main_proto, &functions);

    // Should return 5 + 10 = 15
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 15 });
}

test "two-level function call" {
    // Define add_one: function(x) return x + 1 end
    const add_one_code = [_]Instruction{
        Instruction.initABC(.ADDI, 0, 0, 1), // R[0] = R[0] + 1
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const add_one_proto = Proto{
        .k = &[_]TValue{},
        .code = &add_one_code,
        .numparams = 1,
        .is_vararg = false,
        .maxstacksize = 1,
    };

    // Define call_add_one: function(x) return add_one(x) end
    const call_add_one_code = [_]Instruction{
        Instruction.initABC(.MOVE, 2, 0, 0), // R[2] = R[0] (x)
        Instruction.initABC(.CALL, 1, 2, 2), // R[1] = add_one(R[2])
        Instruction.initABC(.RETURN, 1, 2, 0), // return R[1]
    };
    const call_add_one_proto = Proto{
        .k = &[_]TValue{},
        .code = &call_add_one_code,
        .numparams = 1,
        .is_vararg = false,
        .maxstacksize = 3,
    };

    // Main: return call_add_one(5)
    const main_constants = [_]TValue{
        .{ .integer = 5 },
    };
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 0, 0), // R[0] = 5
        Instruction.initABC(.MOVE, 3, 0, 0), // R[3] = R[0] (argument)
        Instruction.initABC(.CALL, 2, 2, 2), // R[2] = call_add_one(R[3])
        Instruction.initABC(.RETURN, 2, 2, 0), // return R[2]
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    var vm_ext = VMExt.init();

    // Set up functions
    const functions = [_]FunctionMapping{
        .{ .slot = 1, .func = &add_one_proto }, // add_one in slot 1
        .{ .slot = 2, .func = &call_add_one_proto }, // call_add_one in slot 2
    };

    const result = try vm_ext.executeWithFunctions(&main_proto, &functions);

    // Should return 5 + 1 = 6
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 6 });
}

test "function call with multiple arguments" {
    // Define add3 function: function(a, b, c) return a + b + c end
    const add3_code = [_]Instruction{
        Instruction.initABC(.ADD, 3, 0, 1), // R[3] = R[0] + R[1]
        Instruction.initABC(.ADD, 3, 3, 2), // R[3] = R[3] + R[2]
        Instruction.initABC(.RETURN, 3, 2, 0), // return R[3]
    };
    const add3_proto = Proto{
        .k = &[_]TValue{},
        .code = &add3_code,
        .numparams = 3,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    // Main: return add3(10, 20, 30)
    const main_constants = [_]TValue{
        .{ .integer = 10 },
        .{ .integer = 20 },
        .{ .integer = 30 },
    };
    const main_code = [_]Instruction{
        Instruction.initABx(.LOADK, 1, 0), // R[1] = 10
        Instruction.initABx(.LOADK, 2, 1), // R[2] = 20
        Instruction.initABx(.LOADK, 3, 2), // R[3] = 30
        Instruction.initABC(.CALL, 0, 4, 2), // R[0] = add3(R[1], R[2], R[3])
        Instruction.initABC(.RETURN, 0, 2, 0), // return R[0]
    };
    const main_proto = Proto{
        .k = &main_constants,
        .code = &main_code,
        .numparams = 0,
        .is_vararg = false,
        .maxstacksize = 4,
    };

    var vm_ext = VMExt.init();

    // Set up function in slot 0
    const functions = [_]FunctionMapping{
        .{ .slot = 0, .func = &add3_proto },
    };

    const result = try vm_ext.executeWithFunctions(&main_proto, &functions);

    // Should return 10 + 20 + 30 = 60
    try test_utils.ReturnTest.expectSingle(result, .{ .integer = 60 });
}
