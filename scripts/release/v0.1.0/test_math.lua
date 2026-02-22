-- v0.1.0 Release Test: Math Library

print("=== math.abs ===")
assert(math.abs(-5) == 5)
assert(math.abs(5) == 5)
assert(math.abs(-3.14) == 3.14)

print("=== math.floor/ceil ===")
assert(math.floor(3.7) == 3)
assert(math.floor(-3.7) == -4)
assert(math.ceil(3.2) == 4)
assert(math.ceil(-3.2) == -3)

print("=== math.min/max ===")
assert(math.min(1, 2, 3) == 1)
assert(math.max(1, 2, 3) == 3)
assert(math.min(-1, 0, 1) == -1)

print("=== math.sqrt ===")
assert(math.sqrt(4) == 2)
assert(math.sqrt(9) == 3)

print("=== math.sin/cos ===")
assert(math.abs(math.sin(0)) < 0.0001)
assert(math.abs(math.cos(0) - 1) < 0.0001)

print("=== math.exp/log ===")
assert(math.abs(math.exp(0) - 1) < 0.0001)
assert(math.abs(math.log(math.exp(1)) - 1) < 0.0001)

print("=== operator ^ ===")
assert(2^3 == 8)
assert(2^0 == 1)

print("=== math.fmod ===")
assert(math.fmod(10, 3) == 1)

print("=== math.modf ===")
local int, frac = math.modf(3.14)
assert(int == 3)

print("=== math.huge ===")
assert(math.huge > 1e308)

print("=== division by zero (IEEE 754) ===")
assert(1/0 == math.huge)       -- inf
assert(-1/0 == -math.huge)     -- -inf
assert(0/0 ~= 0/0)             -- nan ~= nan (NaN is never equal to itself)

print("=== integer overflow (wrapping) ===")
local max_int = 0x7FFFFFFFFFFFFFFF
local min_int = max_int + 1              -- wraps to min
assert(min_int < 0)                      -- overflow wraps to negative
assert(min_int - 1 == max_int)           -- underflow wraps back
assert(math.type(min_int) == "integer")  -- stays integer

print("=== math.pi ===")
assert(math.abs(math.pi - 3.14159265) < 0.0001)

print("=== math.random ===")
local r = math.random()
assert(r >= 0 and r < 1)
local r2 = math.random(10)
assert(r2 >= 1 and r2 <= 10)
local r3 = math.random(5, 10)
assert(r3 >= 5 and r3 <= 10)

print("=== math.type ===")
assert(math.type(1) == "integer")
assert(math.type(1.0) == "float")
assert(math.type("x") == nil)

print("=== math.tointeger ===")
assert(math.tointeger(3.0) == 3)
assert(math.tointeger(3.5) == nil)

print("=== math.ult ===")
assert(math.ult(1, 2) == true)

print("[PASS] test_math.lua")
