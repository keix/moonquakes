# Moonquakes Lexical and Syntactic Analysis

Moonquakes implements a single-pass compiler that transforms raw Lua source code directly into executable bytecode (Proto).

The design follows Lua's original architecture: lexical analysis separates tokens from source text, while parsing and bytecode emission occur simultaneously in a single pass.

## 1. Overview

Moonquakes compiler performs a two-stage pipeline:

```
Lua Source → Tokens → Proto (Bytecode)
```

| Stage                | Component     | Description                                                                            |
| -------------------- | ------------- | -------------------------------------------------------------------------------------- |
| **Lexical Analysis** | `lexer.zig`   | Converts raw Lua source into a stream of tokens (classification only)                |
| **Parsing & Emission**| `parser.zig`  | Consumes tokens and directly emits bytecode instructions into a `Proto`              |

Moonquakes does not build an intermediate AST. Instead, parsing and bytecode emission are performed in a single pass. This approach reduces memory usage and complexity while maintaining compatibility with Lua's execution model.

## 2. Lexical Analysis (Lexer)

The lexer converts raw Lua source text into a stream of tokens — atomic units like identifiers, keywords, literals, and punctuation.

**Lexer responsibility: Classification only. No semantic meaning.**

### 2.1 Token Structure
```zig
pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
};
```

### 2.2 Token Kinds
```zig
pub const TokenKind = enum {
    Identifier,
    Number,
    String,
    Keyword,
    Symbol,
    Eof,
};
```
In practice, TokenKind will be refined to distinguish individual keywords and symbols to simplify parsing logic.

The lexer scans input character by character, classifying sequences:

| Example   | Token Kind | Lexeme    |
| --------- | ---------- | --------- |
| `local`   | Keyword    | `"local"` |
| `x`       | Identifier | `"x"`     |
| `=`       | Symbol     | `"="`     |
| `42`      | Number     | `"42"`    |
| `"hello"` | String     | `"hello"` |

### 2.3 Responsibilities
- Skip whitespace and comments (-- single-line, --[[ multi-line ]])
- Track line numbers for error reporting
- Support Lua 5.4 literal forms (including hexadecimal and exponential notation)
- Return Eof token at the end of input
- **No allocation** — all lexemes are slices over the original source buffer

## 3. Parsing and Code Emission (Single Pass)

The parser consumes tokens and **immediately emits bytecode**. Each grammar rule produces bytecode instructions directly into a Proto structure.

> **Parsing is code generation.**

### 3.1 Parsing Strategy

Recursive descent parser with immediate bytecode emission:

```text
parseExp()  → emits expression bytecode
parseStat() → emits statement bytecode
parseChunk() → emits chunk bytecode
```

Example grammar (simplified):
```
chunk     ::= { stat [';'] } [ laststat [';'] ]
stat      ::= varlist '=' explist | functioncall | do block end | while exp do block end
exp       ::= nil | false | true | Number | String | function | prefixexp | exp binop exp | unop exp
```

Each grammar rule corresponds to a Zig function that emits bytecode:
```zig
fn parseExp(self: *Parser) !void {
    // Parse expression and emit bytecode immediately
    self.emit(OP_LOADK, reg, const_idx);
}

fn parseStat(self: *Parser) !void {
    // Parse statement and emit bytecode immediately
    self.emit(OP_SETGLOBAL, reg, name_idx);
}
```

### 3.2 ProtoBuilder State

Parser maintains bytecode generation state:

```zig
pub const ProtoBuilder = struct {
    code: std.ArrayList(Instruction),      // Bytecode instructions
    constants: std.ArrayList(TValue),      // Constant pool
    maxstacksize: u8,                     // Register allocation
    patch_list: std.ArrayList(JumpPatch), // Forward jumps
    
    pub fn emit(self: *Self, op: OpCode, a: u8, b: u8, c: u8) void
    pub fn emitJump(self: *Self) u32
    pub fn patchJump(self: *Self, addr: u32)
};
```

### 3.3 Control Flow Implementation

Forward-jump patching handles control structures:

```zig
// Example: while condition do body end
const jump_start = self.emitJump();     // Jump to condition
const body_start = self.code.items.len;
try self.parseBlock();                  // Emit body bytecode
try self.parseExp();                    // Emit condition bytecode
self.emitJumpIf(body_start);           // Jump back to body if true
self.patchJump(jump_start);            // Patch initial jump
```

## 4. Bytecode Output

Parser produces a complete Proto structure:

```zig
pub const Proto = struct {
    code: []Instruction,        // Array of 32-bit instructions
    k: []TValue,               // Constant table
    maxstacksize: u8,          // Number of registers needed
    numparams: u8,             // Function parameters
    is_vararg: bool,           // Vararg function
};
```

Example transformation:

| Lua Source  | Generated Bytecode                                          |
| ----------- | ----------------------------------------------------------- |
| `x = 1 + 2` | `LOADK R0 K0`, `LOADK R1 K1`, `ADD R2 R0 R1`, `SETGLOBAL R2 K2` |

The resulting Proto can be directly passed to the VM's `execute()` function.

## 5. Bytecode Dump (Debug)

Moonquakes includes a bytecode disassembler for debugging and validation:

```
LOADK    R0  K0    ; 1
LOADK    R1  K1    ; 2  
ADD      R2  R0 R1
SETGLOBAL R2  K2   ; x
```

- **Dump is a debugging tool** but bytecode format is first-class
- **VM consumes the same bytes** that dump displays
- Human-readable mnemonics map directly to raw 32-bit instructions

## 6. Design Rationale

**No AST**
- Reduces memory allocation
- Simplifies compiler pipeline  
- Matches Lua's original design

**Fixed-width instructions**
- Predictable encoding/decoding
- Efficient VM dispatch
- Simple instruction format

**Parser-driven register allocation**
- Registers allocated during parsing
- No separate allocation pass needed
- Minimal register usage

**VM/compiler decoupling via Proto**
- Compiler outputs standardized Proto format
- VM only depends on Proto structure
- Clean separation of concerns

## 7. Future Work

| Feature                              | Notes                                       |
| ------------------------------------ | ------------------------------------------- |
| Full expression grammar              | Partial arithmetic ops implemented          |
| Function definitions                 | Proto emission for nested functions        |
| Local/global scope resolution        | Symbol tables during parsing               |
| Error recovery                       | Panic-free parser with diagnostics         |

## 8. Example Flow
Conceptual example

```
Source:
    for i = 1, 3 do
        print(i)
    end

Pipeline:
    [Lexer] → FOR, Identifier(i), '=', Number(1), ',', Number(3), DO, ...
    [Parser] → Directly emits: FORPREP, CALL, FORLOOP instructions
    [VM] → Executes Proto until RETURN
```

**No AST is constructed.** The parser reads tokens and immediately produces executable bytecode.