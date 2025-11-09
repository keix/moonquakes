const std = @import("std");
const TValue = @import("../core/value.zig").TValue;
const Proto = @import("func.zig").Proto;
const CallFrame = @import("do.zig").CallFrame;
const opcodes = @import("../compiler/opcodes.zig");
const OpCode = opcodes.OpCode;
const Instruction = opcodes.Instruction;

pub const VM = struct {
    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?CallFrame,

    pub fn init() VM {
        var vm = VM{
            .stack = undefined,
            .stack_last = 256 - 1,
            .top = 0,
            .base = 0,
            .ci = null,
        };
        for (&vm.stack) |*v| {
            v.* = .nil;
        }
        return vm;
    }

    fn arithBinary(self: *VM, inst: Instruction, comptime op: fn (f64, f64) f64) !void {
        const a = inst.getA();
        const b = inst.getB();
        const c = inst.getC();
        const vb = &self.stack[self.base + b];
        const vc = &self.stack[self.base + c];

        // Try integer arithmetic first for add, sub, mul
        if (op == addOp or op == subOp or op == mulOp) {
            if (vb.isInteger() and vc.isInteger()) {
                const ib = vb.integer;
                const ic = vc.integer;
                if (op == addOp) {
                    self.stack[self.base + a] = .{ .integer = ib + ic };
                } else if (op == subOp) {
                    self.stack[self.base + a] = .{ .integer = ib - ic };
                } else if (op == mulOp) {
                    self.stack[self.base + a] = .{ .integer = ib * ic };
                }
                return;
            }
        }

        // Fall back to floating point
        const nb = vb.toNumber();
        const nc = vc.toNumber();
        if (nb != null and nc != null) {
            self.stack[self.base + a] = .{ .number = op(nb.?, nc.?) };
        } else {
            return error.ArithmeticError;
        }
    }

    fn addOp(a: f64, b: f64) f64 {
        return a + b;
    }
    fn subOp(a: f64, b: f64) f64 {
        return a - b;
    }
    fn mulOp(a: f64, b: f64) f64 {
        return a * b;
    }
    fn divOp(a: f64, b: f64) f64 {
        return a / b;
    }
    fn idivOp(a: f64, b: f64) f64 {
        return @floor(a / b);
    }
    fn modOp(a: f64, b: f64) f64 {
        return @mod(a, b);
    }

    pub const ReturnValue = union(enum) {
        none,
        single: TValue,
        multiple: []TValue,
    };

    pub fn execute(self: *VM, proto: *const Proto) !ReturnValue {
        self.ci = CallFrame{
            .func = proto,
            .pc = proto.code.ptr,
            .base = 0,
            .top = proto.maxstacksize,
        };
        self.base = 0;
        self.top = proto.maxstacksize;

        while (true) {
            var ci = &self.ci.?;
            const inst = ci.pc[0];
            ci.pc += 1;

            const op = inst.getOpCode();
            const a = inst.getA();

            switch (op) {
                .MOVE => {
                    const b = inst.getB();
                    self.stack[self.base + a] = self.stack[self.base + b];
                },
                .LOADK => {
                    const bx = inst.getBx();
                    self.stack[self.base + a] = proto.k[bx];
                },
                .ADD => {
                    try self.arithBinary(inst, addOp);
                },
                .SUB => {
                    try self.arithBinary(inst, subOp);
                },
                .MUL => {
                    try self.arithBinary(inst, mulOp);
                },
                .DIV => {
                    try self.arithBinary(inst, divOp);
                },
                .IDIV => {
                    try self.arithBinary(inst, idivOp);
                },
                .MOD => {
                    try self.arithBinary(inst, modOp);
                },
                .UNM => {
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];
                    if (vb.isInteger()) {
                        self.stack[self.base + a] = .{ .integer = -vb.integer };
                    } else if (vb.toNumber()) |n| {
                        self.stack[self.base + a] = .{ .number = -n };
                    } else {
                        return error.ArithmeticError;
                    }
                },
                .NOT => {
                    const b = inst.getB();
                    const vb = &self.stack[self.base + b];
                    self.stack[self.base + a] = .{ .boolean = !vb.toBoolean() };
                },
                .RETURN => {
                    const b = inst.getB();
                    if (b == 0) {
                        // return no values (used internally for tailcall)
                        return .none;
                    } else if (b == 1) {
                        // return nothing (return)
                        return .none;
                    } else if (b == 2) {
                        // return 1 value from R[A]
                        return .{ .single = self.stack[self.base + a] };
                    } else {
                        // return n-1 values from R[A]..R[A+n-2]
                        const count = b - 1;
                        const values = self.stack[self.base + a .. self.base + a + count];
                        return .{ .multiple = values };
                    }
                },
                else => return error.UnknownOpcode,
            }
        }
    }
};
