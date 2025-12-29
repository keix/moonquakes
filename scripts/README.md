# Test Scripts
This directory contains Lua scripts for testing Moonquakes functionality.

## Test Categories

### Arithmetic
- `arithmetic/` - Basic arithmetic operations
  - `divide.lua` - Division operations
  - `modulo.lua` - Modulus operations
  - `multiply.lua` - Multiplication operations
  - `subtract.lua` - Subtraction operations

### Basics
- `basics/` - Basic language features
  - `number.lua` - Number literals
  - `print_42.lua` - Simple output test
  - `string.lua` - String literal testing

### Comparisons
- `comparisons/` - Comparison operators
  - `equal_5_5.lua` - Equality testing
  - `false_1_2.lua` - False condition test
  - `true_1_1.lua` - True condition test

### Control Flow
- `control_flow/` - Control structures
  - `if.lua` - Basic if/else statements
  - `elseif.lua` - Complex elseif chains
  - `for.lua` - Basic for loops

### FizzBuzz
- `fizzbuzz/` - FizzBuzz implementations and variations
  - `buzz_condition.lua` - Buzz condition testing
  - `complex_condition.lua` - Complex conditional logic
  - `division_equals.lua` - Division equality testing
  - `fizz_condition.lua` - Fizz condition testing
  - `fizzbuzz.lua` - Complete FizzBuzz implementation
  - `fizzbuzz_condition.lua` - FizzBuzz condition testing
  - `fizzbuzz_simple_if.lua` - Simple if-based FizzBuzz

### Functions
- `function/` - Function call testing
  - `global/print.lua` - Global print function
  - `global/tostring.lua` - String conversion function
  - `io/write.lua` - I/O write function

## Usage
Examples:

```sh
zig build run -- scripts/basics/print_42.lua
zig build run -- scripts/fizzbuzz/fizzbuzz.lua
zig build run -- scripts/function/global/tostring.lua
```

## Currently Supported Features

- Number literals and arithmetic operations
- Boolean literals and comparison operators
- String literals and string output
- Control flow (if/then/else/elseif)
- For loops with variable access
- Native function calls (print, tostring, io.write)
- Global environment and table access