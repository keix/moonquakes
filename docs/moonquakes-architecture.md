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

## 2. Call Frames and Execution Context
Each active function call in Moonquakes is represented by a CallInfo.
A CallInfo stores all the state necessary to resume a function — including the current program counter (pc), the base index of its stack segment, the return base for results, and its associated function prototype (Proto).

Conceptually, a CallInfo is similar to a lightweight stack frame in a CPU, but designed for a register-based virtual machine.

### 2.1 Structure
```
pub const CallInfo = struct {
    func: *const Proto,              // the function prototype being executed
    pc: [*]const Instruction,        // pointer to current instruction
    base: u32,                       // base register index in VM stack
    ret_base: u32,                   // where to place return values in caller's frame
    savedpc: ?[*]const Instruction,  // saved pc for yielding
    nresults: i16,                   // expected number of results (-1 = multiple)
    previous: ?*CallInfo,            // previous frame in the call stack
};
```

Each frame defines a register window — a contiguous region of the global VM stack used by that function. Registers R[base] through R[top-1] belong exclusively to that function, isolating it from others.

### 2.2 Relation to the VM
When a function is called, the VM:

- Pushes a new frame (CallInfo) onto its internal call stack.
- Sets the frame’s base to the current stack top.
- Executes instructions in the function’s bytecode (Proto.code).
- When a RETURN opcode is reached, the frame is popped, and control returns to the caller.

In Moonquakes, the VM now supports multiple active frames with a proper call stack, allowing nested function calls up to 20 levels deep.

### 2.3 Stack and Register Mapping
The global VM stack holds all registers for all active frames:

```
+---------------------------------+  
|  R0  |  R1  |  R2  |  R3  | ... |  
+---------------------------------+  
^base                             ^top
```

Each instruction refers to registers using relative indices from the frame base:

```
R[A] = stack[frame.base + A]
```

This design mirrors Lua’s register-based model — efficient, predictable, and well-suited for JIT or ahead-of-time compilation.

## 3. Function Prototype (Proto)
In Moonquakes, every function — whether it’s a Lua script or a nested function — is represented by a Proto structure.

A Proto encapsulates the immutable components of a compiled Lua function: its constants, bytecode, local variable count, and stack size requirements.

Unlike a CallInfo, which is runtime state, a Proto is compile-time data that can be shared and executed multiple times.

### 3.1 Structure
```
pub const Proto = struct {
    k: []const TValue,      // constant table (literals, numbers, strings)
    code: []const u32,      // array of 32-bit encoded instructions
    numparams: u8,          // number of formal parameters
    is_vararg: bool,        // whether function accepts variable arguments
    maxstacksize: u8,       // required register count
};
```

Each Proto defines the static blueprint for execution:

- k holds constants referenced by opcodes that use the k flag.
- code contains the VM bytecode sequence, each entry a 32-bit instruction.
- numparams and is_vararg define the function signature.
- maxstacksize declares how many registers (stack slots) must be reserved.

The VM does not allocate dynamically per instruction — it reserves the entire maxstacksize at frame setup. This design ensures predictable stack access and constant-time register lookups.

### 3.2 Relationship Between Proto and CallInfo

When executing, the VM binds a Proto to a CallInfo:

```
CallInfo {
    func = &Proto
    base = stack_base
    ret_base = caller_result_base
    nresults = expected_results
    previous = &caller_CallInfo
}
```

Conceptually:

```
Proto (definition) → CallInfo (activation) → VM (execution)
```

- The Proto is static — it never changes.
- The CallInfo is dynamic — it represents one active invocation of that Proto.
- The VM manages both — loading constants, fetching instructions, updating registers.

## 4. Execution Loop (Fetch–Decode–Execute)

At the heart of Moonquakes lies a classic fetch–decode–execute cycle —
a simple loop that continuously fetches the next instruction, decodes it, and executes it against the active stack frame.

Pseudocode overview:

```
while true:
    inst = frame.pc[0]
    frame.pc += 1
    decode op, A, B, C from inst

    switch op:
        case MOVE:
            R[A] = R[B]
        case LOADK:
            R[A] = K[Bx]
        case ADD:
            R[A] = R[B] + R[C]
        ...
        case RETURN:
            return result
```

This design remains faithful to Lua’s philosophy — a register-based virtual machine that trades off bytecode compactness for execution speed and simplicity.

Every instruction executes in constant time, without additional heap allocations or indirection.