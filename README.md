# Moonquakes
An interpretation of Lua

## Overview
Moonquakes is a clean-room implementation of the **Lua 5.4** virtual machine and runtime.

It is not a binding to the official C implementation — instead, it aims to reimagine the key components of Lua with a clear, modern design and a focus on readability, correctness, and hackability.

Even decades after its creation, Lua's architecture remains one of the most elegant and minimal designs in language engineering — small, clear, yet powerful enough to move worlds.

Moonquakes carries that elegance forward — rewritten in Zig.

## Architecture
The internal structure of Moonquakes — including the VM design, instruction formats, call frames, and execution flow — is documented here:

[Moonquakes Architecture](docs/moonquakes-architecture.md)

Moonquakes intentionally avoids intermediate representations where they are not essential.  Parsing and bytecode emission occur in a single pass, mirroring the original Lua compiler design.

The resulting bytecode serves as both the execution format and the primary debugging surface, making the system easy to inspect, reason about, and extend.

## Lua Specification 
Lua 5.4 Reference Manual

[https://www.lua.org/manual/5.4/](https://www.lua.org/manual/5.4/)

Moonquakes is developed with the long-term goal of fully implementing the Lua 5.4 specification. Not all features are complete yet, but every part is designed to stay faithful to the official spec.

## Acknowledgments
Moonquakes is inspired by the elegance of the original Lua authors:  
Roberto Ierusalimschy, Luiz Henrique de Figueiredo, and Waldemar Celes.

Their work defined not only a language, but a philosophy of simplicity that still resonates today.

## License
Copyright KEI SAWAMURA 2025.  
Moonquakes is licensed under the MIT License. Copying and modifying is encouraged and appreciated.

