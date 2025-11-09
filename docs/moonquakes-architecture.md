# Moonquakes Architecture
Moonquakes is a clean implementation of the Lua 5.4 virtual machine and runtime, written entirely in Zig.

Rather than binding to the existing C codebase, it reimagines the Lua execution model with modern clarity, explicit memory control, and a focus on readability over historical constraints.

The goal is not to create a direct port, but to reconstruct Lua’s core — values, bytecode, virtual machine, and eventually its standard library — in a way that is transparent, hackable, and faithful to the spirit of the language.

This document describes the internal architecture of Moonquakes: how the VM is structured, how instructions are encoded and executed, how values are represented, and how components such as prototypes, call frames, and runtime state interact. It serves as a technical map for contributors and for future phases of development.

## 1. Instruction Format
Moonquakes follows the same 32-bit instruction format used by the official Lua 5.4 virtual machine.  

Every instruction is exactly one 32-bit word and is divided into several fields: **OpCode**, **A**, **k**, **B**, and **C**, or into larger composite fields depending on instruction mode.

### 1.1 Bit Layout (iABC format)
The most common instruction layout is iABC:

```
+--------+--------+--------+--------+--------+  
| Op     | A      | k      | B      | C      |  
+--------+--------+--------+--------+--------+
7 bits   8 bits   1 bit    8 bits   8 bits
```

| Field | Bits | Description |
|-------|------|-------------|
| **Op** | 7   | Opcode (which instruction to execute) |
| **A**  | 8   | Usually the destination register (`R[A]`) |
| **k**  | 1   | Constant flag: if `1`, operands B or C refer to constants (`K[]`) rather than registers (`R[]`) |
| **B**  | 8   | Second operand: register index or constant index depending on `k` |
| **C**  | 8   | Third operand: same as B (register or constant) |

### 1.2 Instruction Modes
Even though every instruction is exactly 32 bits wide, not every opcode needs three separate operands. Some instructions need two registers and a constant, some require a large constant index, and others require a signed jump offset.

Instead of using variable-length bytecode, Lua changes *how those 32 bits are interpreted* depending on the instruction. These interpretations are called **instruction modes**.

In that sense, instruction modes are similar to CPU addressing modes:

they don’t change the length of the instruction, but they change *how the bits are decoded into operands*.

| Mode  | Structure                           | Used by                    |
|-------|-------------------------------------|----------------------------|
| **iABC**  | Op (7) + A (8) + k (1) + B (8) + C (8) | `MOVE`, `ADD`, `GETTABLE`, `SETTABLE`, ... |
| **iABx**  | Op (7) + A (8) + Bx (17)             | `LOADK`, `CLOSURE` |
| **iAsBx** | Op (7) + A (8) + sBx (signed Bx)     | `JMP`, `FORPREP`, `FORLOOP` |
| **iAx**   | Op (7) + Ax (25)                     | `EXTRAARG` |
| **isJ**   | Op (7) + sJ (signed jump offset)     | Tail-call and upvalue close instructions |

Where:

- `A`, `B`, `C` refer to registers (`R[A]`) or constants (`K[B]`, `K[C]`)  
- `k` tells whether B/C are registers (`k = 0`) or constants (`k = 1`)  
- `Bx` is an unsigned 17-bit field created by combining B, C, and k  
- `sBx` is a signed version of Bx (interpreted as `Bx - OFFSET`)  
- `Ax` is a 25-bit payload used by instructions like `EXTRAARG`  
- `sJ` is a signed jump offset used for control flow in newer opcodes (Lua 5.4)

This design keeps the VM simple: fixed-width 32-bit instructions, no decoding overhead, and yet flexible enough to encode constants, jumps, and register operands.

### 1.3 Constant Flag (`k`)
The **k bit** determines whether operands B and C refer to registers or constants:

| k | Meaning |
|---|---------|
| `0` | Operands B and C refer to registers (`R[B]`, `R[C]`) |
| `1` | Operands refer to constants in the constant table (`K[B]`, `K[C]`) |

Example (conceptual Lua semantics):

```
; Without k (using registers)
ADD R1 R2 R3 ; R1 = R2 + R3

; With k (using a constant)
ADDK R1 R2 K5 ; R1 = R2 + K[5]
```

Next, we will describe how instructions are executed inside the VM loop, how registers map to stack slots, and how a Proto (function prototype) stores bytecode and constants.
