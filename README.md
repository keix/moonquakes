# Moonquakes
An interpretation of Lua

## Why Moonquakes?
Moonquakes imagines Lua as moonlight at night — still on the surface, quietly trembling beneath as time moves on. It reflects the sunlight, forever.

## Overview
Moonquakes is a clean-room implementation of the **Lua 5.4** virtual machine and runtime.

It is not a binding to the official C implementation — instead, it aims to reimagine the key components of Lua with a clear, modern design and a focus on readability, correctness, and hackability.

Even decades after its creation, Lua's architecture remains one of the most elegant and minimal designs in language engineering — small, clear, yet powerful enough to move worlds.

Moonquakes carries that elegance forward — rewritten in Zig.

## Dependencies
Moonquakes has intentionally minimal dependencies.  
No external libraries, system runtimes, or original Lua source code are required.

- **Zig compiler 0.15.2** (required)

As Zig evolves, compiler and build APIs may change.

For a stable and reproducible environment, using Nix is recommended.
Nix is optional and leaves your system untouched.

```sh
nix develop
```

## Moonquakes Build
Moonquakes is built with Zig.  
For normal use and evaluation, build with optimizations enabled:
```sh
zig build -Doptimize=ReleaseSafe
```

## Running Moonquakes

After building:

```sh
./zig-out/bin/moonquakes
```

## C Interface (Experimental)
Moonquakes exposes a minimal C interface for embedding.  
The public boundary is defined in [`include/moonquakes.h`](include/moonquakes.h).

To build the static and shared libraries:

```sh
make
```

## Running C Example
To run the example:
```sh
LD_LIBRARY_PATH=build/lib ./build/bin/minimal
```

## Architecture
Moonquakes follows a clean, modular design inspired by the original Lua architecture, prioritizing clarity, minimalism, and structural integrity.

For detailed design and implementation notes, see the documentation in [docs/](docs/).

## Project Notes
Moonquakes is an active work in progress.
Opcode coverage, implementation milestones, and design notes are tracked publicly to ensure transparency and long-term maintainability.

For detailed progress tracking and internal design documentation, see:  
Moonquakes Project Notes (Notion) https://lua-v5.notion.site/

This page includes opcode checklists, architectural decisions, and future milestones, serving as a living companion to the source code.

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
