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

    pub fn execute(self: *VM, proto: *const Proto) !?TValue {
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
                    const b = inst.getB();
                    const c = inst.getC();
                    const vb = &self.stack[self.base + b];
                    const vc = &self.stack[self.base + c];

                    const nb = vb.toNumber();
                    const nc = vc.toNumber();
                    if (nb != null and nc != null) {
                        self.stack[self.base + a] = .{ .number = nb.? + nc.? };
                    } else {
                        const ib = vb.toInteger();
                        const ic = vc.toInteger();
                        if (ib != null and ic != null) {
                            self.stack[self.base + a] = .{ .integer = ib.? + ic.? };
                        } else {
                            return error.ArithmeticError;
                        }
                    }
                },
                .RETURN => {
                    const b = inst.getB();
                    if (b == 0) {
                        return null;
                    } else if (b == 1) {
                        return null;
                    } else {
                        return self.stack[self.base + a];
                    }
                },
                else => return error.UnknownOpcode,
            }
        }
    }
};
