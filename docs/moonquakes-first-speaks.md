# Moonquakes first speaks
Define and implement the smallest possible Lua 5.4 VM in Zig that can execute a hand-crafted chunk:

```lua
return 1 + 2
```

## Milestones
- Define TValue (nil, boolean, integer, number)
- Define opcode format (iABC)
- Implement LOADK, MOVE, ADD, RETURN
- Hardcode a prototype chunk into VM
- Execute it and print the result → "moonquakes speaks for the first time"


## 1. Purpose
This document records the journey to bring the **first breath** of the Lua 5.4 
virtual machine to life in Zig —  
from zero to the moment the VM executes its first instruction and returns a value.

## 2. Scope of Phase 1 – “First Speaks”

What is included:
- A minimal Lua 5.4 VM implemented in Zig
- TValue (nil, boolean, integer, number only)
- Stack and CallInfo
- Prototype (Proto) structure with constants and bytecode
- Hand-written bytecode execution (no parser/lexer yet)

What is explicitly out of scope (for now):
- Lexer / Parser
- Garbage Collector
- Tables, strings, metatables
- Closures / upvalues / environments (`_ENV`)
- Coroutines
- C API (`lua_State`, `lua_push*`, etc.)

## 3. Minimal VM Architecture

Planned components:
- **TValue** — tagged union for fundamental types
- **CallInfo & Stack** — register-based VM model
- **Proto** — function prototype with constants + instructions
- **Instruction format (iABC)** — 32-bit packed opcodes
- **VM Loop** — fetch → decode → execute

## 4. First Chunk to Execute

Target Lua code:
```lua
return 1 + 2
```

This will be manually translated to a bytecode chunk (Prototype), for example:

```
LOADK   R0, K1      ; R0 = 1
LOADK   R1, K2      ; R1 = 2
ADD     R2, R0, R1  ; R2 = R0 + R1
RETURN  R2, 1       ; return R2
```

## 5. Instruction Set for Phase 1

| Opcode | Description                   |
| ------ | ----------------------------- |
| LOADK  | R[A] = constant[Bx]           |
| MOVE   | R[A] = R[B]                   |
| ADD    | R[A] = R[B] + R[C]            |
| RETURN | return R[A], next (B results) |

Only these four are required for the VM to "speak" for the first time.

## 6. Implementation Order

- Define TValue (core/value.zig)
- Define opcode enums and instruction format (compiler/opcodes.zig)
- Implement VM struct and main dispatch loop (vm/vm.zig)
- Implement CallInfo and stack handling
- Hardcode a minimal Proto with bytecode for return 1 + 2
- Execute through repl.zig and print the result

## 7. When Moonquakes Speaks
To be filled at the moment of success:

- Date and commit hash
- The bytecode executed
- Output (expected and actual)
- Notes, thoughts, surprises

## 8. What Comes After
Possible next steps beyond Phase 1:

- Add lexer and parser
- Implement tables and _ENV
- Introduce closures and upvalues
- Implement a minimal mark-sweep GC
- Build the base standard library
