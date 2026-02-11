-- Test MMBINI and MMBINK opcodes
-- MMBINI: metamethod for binary op with immediate value
-- MMBINK: metamethod for binary op with constant value

local mt = {
    __add = function(a, b)
        if type(a) == "table" then
            return a.value + b
        else
            return a + b.value
        end
    end,
    __sub = function(a, b)
        if type(a) == "table" then
            return a.value - b
        else
            return a - b.value
        end
    end,
    __mul = function(a, b)
        if type(a) == "table" then
            return a.value * b
        else
            return a * b.value
        end
    end,
    __div = function(a, b)
        if type(a) == "table" then
            return a.value / b
        else
            return a / b.value
        end
    end
}

local obj = setmetatable({value = 10}, mt)

-- MMBINI tests (immediate values)
assert(obj + 5 == 15, "obj + 5")
assert(5 + obj == 15, "5 + obj")
assert(obj - 3 == 7, "obj - 3")
assert(20 - obj == 10, "20 - obj")
assert(obj * 2 == 20, "obj * 2")
assert(3 * obj == 30, "3 * obj")

-- MMBINK tests (constant values)
local big = 1000
assert(obj + big == 1010, "obj + big")
assert(big + obj == 1010, "big + obj")
assert(obj * big == 10000, "obj * big")
assert(obj / 2 == 5, "obj / 2")

print("mmbini_mmbink passed")
