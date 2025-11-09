# Moonquakes
A clean Zig interpretation of Lua — not bound to its C past, but faithful to its spirit.

## Overview
Moonquakes is a clean-room implementation of the **Lua 5.4** virtual machine and runtime, written entirely in Zig. It is not a binding to the official C implementation — instead, it aims to reimplement the key components of Lua with a clear, modern design and a focus on readability, correctness, and hackability.

## Architecture

The internal structure of Moonquakes — including the VM design, instruction formats, call frames, and execution flow — is documented here:

[MoonQuakes Architecture](docs/moonquakes-architecture.md/)

## Lua Specification 
Lua 5.4 Reference Manual

[https://www.lua.org/manual/5.4/](https://www.lua.org/manual/5.4/)

Moonquakes is developed with the long-term goal of fully implementing the Lua 5.4 specification.
Not all features are complete yet, but every part is designed to stay faithful to the official spec.

## License
Copyright KEI SAWAMURA 2025.  
Claudia is licensed under the MIT License. Copying, sharing, and modifying is encouraged and appreciated.
