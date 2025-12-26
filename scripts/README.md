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
- `eq_simple.lua` - Basic equality comparison
- `equal_5_5.lua` - 5 == 5
- `true_1_1.lua` - 1 == 1 (true)
- `false_1_2.lua` - 1 == 2 (false)

### `fizzbuzz/`
FizzBuzz condition tests
- `fizz_condition.lua` - Fizz condition (3 % 3 == 0)
- `buzz_condition.lua` - Buzz condition (5 % 5 == 0)
- `fizzbuzz_condition.lua` - FizzBuzz condition (15 % 15 == 0)
- `normal_number.lua` - Normal number (7 % 3 == 1)
- `complex_condition.lua` - Complex condition (15 % 3 == 0)
- `division_equals.lua` - Division equality test (15 / 3 == 5)
- `fizzbuzz.lua` - Complete FizzBuzz program (commented out)

### `tests/`
Development tests and legacy files
- `if_simple.lua` - Basic if-then-else with boolean literals
- `if_condition.lua` - If statement with comparison (5 == 5)
- `if_fizz.lua` - FizzBuzz condition test (15 % 3 == 0)
- `legacy_math*.lua` - Old math tests
- `05_print_test.zig` - Print function test code in Zig

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

**Implemented:**
- Number literals (integers)
- Boolean literals (true, false)
- Arithmetic operations (+, -, *, /, %)
- Comparison operators (==, !=)
- if-then-else statements
- return statements

**In Development:**
- for loops
- print function
- string literals

## Expected Test Results

- `basics/number.lua` → 15
- `arithmetic/modulo.lua` → 0
- `fizzbuzz/fizz_condition.lua` → true
- `comparisons/true_1_1.lua` → true
- `tests/if_simple.lua` → 1
- `tests/if_condition.lua` → 42
- `tests/if_fizz.lua` → 1