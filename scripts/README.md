# Moonquakes Scripts

This directory contains organized Lua test scripts for the moonquakes interpreter.

## Directory Structure

### `basics/`
Basic functionality tests
- `number.lua` - Simple number literal (return 15)
- `print_42.lua` - Number output test (return 42)

### `arithmetic/`
Four basic arithmetic operations
- `multiply.lua` - Multiplication (3 * 5)
- `subtract.lua` - Subtraction (10 - 3)
- `divide.lua` - Division (15 / 3)
- `modulo.lua` - Modulus (15 % 3)

### `comparisons/`
Comparison operators
- `equal_5_5.lua` - 5 == 5 (true)
- `true_1_1.lua` - 1 == 1 (true)
- `false_1_2.lua` - 1 == 2 (false)

### `control_flow/`
Control flow statements and loops
- **If Statements:**
  - `if_simple.lua` - Basic if-then-else with boolean literals
  - `if_condition.lua` - If statement with comparison (5 == 5)
  - `if_fizz.lua` - FizzBuzz condition test (15 % 3 == 0)
  - `elseif_test.lua` - Complex elseif chains
- **For Loops:**
  - `for_simple.lua` - Basic for loop (1 to 3)
  - `simple_for.lua` - Simple for loop test
  - `for_fixed.lua` - For loop with fixed return value
  - `for_values.lua` - For loop value iteration test
  - `for_with_if.lua` - For loop combined with if statements
  - `for_with_elseif.lua` - For loop with elseif (working FizzBuzz pattern)
  - `for_if_simple.lua` - Simple for+if combination
  - `for_debug.lua` - For loop debugging test

### `fizzbuzz/`
FizzBuzz implementation and condition tests
- **Conditions:**
  - `fizz_condition.lua` - Fizz condition (3 % 3 == 0)
  - `buzz_condition.lua` - Buzz condition (5 % 5 == 0)
  - `fizzbuzz_condition.lua` - FizzBuzz condition (15 % 15 == 0)
  - `normal_number.lua` - Normal number (7 % 3 == 1)
  - `complex_condition.lua` - Complex condition (15 % 3 == 0)
  - `division_equals.lua` - Division equality test (15 / 3 == 5)
- **Complete Programs:**
  - `fizzbuzz.lua` - Complete FizzBuzz program
  - `fizzbuzz_simple_if.lua` - FizzBuzz using if statements
  - `fizzbuzz_step1.lua` - FizzBuzz step-by-step test

### `development/`
Development and legacy test files
- **Legacy Math Tests:**
  - `legacy_math1.lua` - Old math test (3 + 4)
  - `legacy_math2.lua` - Old math test (10 - 3)
  - `legacy_math3.lua` - Old math test (3 * 5)
- **Feature Development:**
  - `print_test.lua` - Print function testing
  - `string_literal.lua` - String literal test

## Usage

```bash
# Basic number test
./zig-out/bin/moonquakes scripts/basics/number.lua

# Arithmetic test
./zig-out/bin/moonquakes scripts/arithmetic/multiply.lua

# FizzBuzz condition test
./zig-out/bin/moonquakes scripts/fizzbuzz/fizz_condition.lua
```

## Currently Supported Features

**Fully Implemented:**
- Number literals (integers and floats)
- Boolean literals (true, false)
- String literals ("hello", "Fizz", "Buzz")
- Arithmetic operations (+, -, *, /, %)
- Comparison operators (==, !=)
- if-then-else statements
- for loops (numeric for with step)
- return statements

**In Development:**
- print function (native call integration)
- Loop variable access (accessing 'i' in for loops)
- Function call syntax
- elseif statements

## Usage Examples

```bash
# Basic arithmetic
./zig-out/bin/moonquakes scripts/arithmetic/multiply.lua

# String literals
./zig-out/bin/moonquakes scripts/tests/string_literal.lua

# For loops
./zig-out/bin/moonquakes scripts/tests/for_simple.lua

# Complex conditions (FizzBuzz logic)
./zig-out/bin/moonquakes scripts/fizzbuzz/fizz_condition.lua

# Complete FizzBuzz (for demonstration)
./zig-out/bin/moonquakes scripts/fizzbuzz/fizzbuzz.lua
```

## Expected Test Results

**Basics:**
- `basics/number.lua` → 15
- `basics/print_42.lua` → 42

**Arithmetic:**
- `arithmetic/multiply.lua` → 15
- `arithmetic/modulo.lua` → 0

**Comparisons:**
- `comparisons/true_1_1.lua` → true
- `comparisons/false_1_2.lua` → false

**Control Flow:**
- `tests/if_simple.lua` → 1
- `tests/if_condition.lua` → 42
- `tests/for_simple.lua` → 1

**FizzBuzz:**
- `fizzbuzz/fizz_condition.lua` → true
- `fizzbuzz/division_equals.lua` → true

**String Literals:**
- `tests/string_literal.lua` → "Fizz"

## Implementation Status

Moonquakes now supports most core Lua features needed for basic programming:

- **Lexical Analysis** - Complete tokenizer for Lua syntax
- **Arithmetic** - All basic math operations with proper precedence
- **Control Flow** - if/then/else statements with boolean logic
- **Loops** - for loops with FORPREP/FORLOOP bytecode
- **Data Types** - integers, floats, booleans, strings
- **VM Safety** - PC range checking and robust error handling

**Next Major Milestones:**
1. Loop variable access (referencing `i` in for loops)
2. Function call syntax integration
3. Complete FizzBuzz program execution
