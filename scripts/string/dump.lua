-- Test string.dump and load

-- Test 1: Simple function dump and load
local function add(a, b)
    return a + b
end

local dumped = string.dump(add)
assert(type(dumped) == "string", "dump should return a string")
assert(#dumped > 0, "dumped string should not be empty")

-- Check that it starts with the magic signature
assert(string.byte(dumped, 1) == 27, "should start with ESC")
assert(string.sub(dumped, 2, 4) == "MOO", "should have MOO signature")

-- Load the dumped function
local loaded = load(dumped)
assert(type(loaded) == "function", "load should return a function")
assert(loaded(3, 4) == 7, "loaded function should work correctly")

-- Test 2: Function with upvalues (closure)
local x = 10
local function with_upvalue(a)
    return a + x
end

local dumped2 = string.dump(with_upvalue)
assert(type(dumped2) == "string", "dump closure should return a string")

-- Note: When loading, upvalues are not preserved - they become nil
-- This is expected Lua behavior

-- Test 3: Function with constants
local function with_constants()
    local a = 42
    local b = "hello"
    local c = 3.14
    local d = true
    local e = nil
    return a, b, c, d, e
end

local dumped3 = string.dump(with_constants)
local loaded3 = load(dumped3)
local a, b, c, d, e = loaded3()
assert(a == 42, "integer constant should be preserved")
assert(b == "hello", "string constant should be preserved")
assert(c == 3.14, "number constant should be preserved")
assert(d == true, "boolean constant should be preserved")
assert(e == nil, "nil constant should be preserved")

-- Test 4: Function with nested function
local function outer()
    local function inner(x)
        return x * 2
    end
    return inner
end

local dumped4 = string.dump(outer)
local loaded4 = load(dumped4)
local inner_fn = loaded4()
assert(inner_fn(5) == 10, "nested function should work")

-- Test 5: Strip option
local dumped_strip = string.dump(add, true)
assert(type(dumped_strip) == "string", "stripped dump should return a string")
assert(#dumped_strip <= #dumped, "stripped should not be larger")

local loaded_strip = load(dumped_strip)
assert(loaded_strip(10, 20) == 30, "stripped function should work")

-- Test 6: Vararg function
local function vararg(...)
    local sum = 0
    for _, v in ipairs({...}) do
        sum = sum + v
    end
    return sum
end

local dumped5 = string.dump(vararg)
local loaded5 = load(dumped5)
assert(loaded5(1, 2, 3, 4, 5) == 15, "vararg function should work")

print("All string.dump tests passed!")
