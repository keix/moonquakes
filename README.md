# Moonquakes
An interpretation of Lua

## Why Moonquakes?
Moonquakes imagines Lua as moonlight at night — still on the surface, quietly trembling beneath as time moves on. It reflects the sunlight, forever.

## Overview
Moonquakes is a clean-room implementation of the **Lua 5.4** virtual machine and runtime.

It is not a binding to the official C implementation — instead, it aims to reimagine the key components of Lua with a clear, modern design and a focus on readability, correctness, and hackability.

Even decades after its creation, Lua's architecture remains one of the most elegant and minimal designs in language engineering — small, clear, yet powerful enough to move worlds.

Moonquakes carries that elegance forward — rewritten in Zig.


## Build
Moonquakes is built with Zig.

```sh
zig build
```

## Architecture
Moonquakes follows a clean, modular design inspired by the original Lua architecture, prioritizing clarity, minimalism, and structural integrity.

For detailed design and implementation notes, see the documentation in [docs/](docs/).
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
