-- Comprehensive multiple return value tests

-- Test 1: Local function returning constants
local function f()
    return 1, 2, 3
end

local a, b, c = f()
assert(a == 1 and b == 2 and c == 3, "Test 1 failed: local assign from constants")

-- Test 2: Local function returning local variables
local function g()
    local x, y, z = 10, 20, 30
    return x, y, z
end

local d, e, f2 = g()
assert(d == 10 and e == 20 and f2 == 30, "Test 2 failed: local assign from locals")

-- Test 3: Print with multi-return (visual check)
print("Test 3:", f())  -- Should print: Test 3: 1 2 3

-- Test 4: Multi-return as last argument
local function sum3(a, b, c)
    return a + b + c
end

local result = sum3(f())
assert(result == 6, "Test 4 failed: multi-return as all args")

-- Test 5: Multi-return following fixed arg
local function add_and_sum(x, a, b, c)
    return x + a + b + c
end

local result2 = add_and_sum(100, f())
assert(result2 == 106, "Test 5 failed: multi-return after fixed arg")

-- Test 6: math.modf returns two values
local int_part, frac_part = math.modf(5.75)
assert(int_part == 5, "Test 6 failed: modf integer part")
assert(math.abs(frac_part - 0.75) < 0.001, "Test 6 failed: modf fractional part")

-- Test 7: Nested function calls with multi-return
local function double(x)
    return x * 2
end

local function triple(x)
    return x * 3
end

local function make_pair()
    return 10, 20
end

local p, q = make_pair()
local dp = double(p)
local tq = triple(q)
assert(dp == 20 and tq == 60, "Test 7 failed: operations on multi-return values")

print("All multi_return tests passed!")
