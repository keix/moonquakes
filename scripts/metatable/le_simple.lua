-- Simple __le test
local mt = {
    __le = function(a, b)
        -- Compare by 'value' field
        return a.value <= b.value
    end
}

local obj1 = { value = 10 }
local obj2 = { value = 20 }
local obj3 = { value = 10 }

setmetatable(obj1, mt)
setmetatable(obj2, mt)
setmetatable(obj3, mt)

-- obj1 <= obj2 should be true (10 <= 20)
print("obj1 <= obj2:", obj1 <= obj2)
assert(obj1 <= obj2, "obj1 should be <= obj2")

-- obj2 <= obj1 should be false (20 <= 10)
print("obj2 <= obj1:", obj2 <= obj1)
assert(not (obj2 <= obj1), "obj2 should not be <= obj1")

-- obj1 <= obj3 should be true (10 <= 10)
print("obj1 <= obj3:", obj1 <= obj3)
assert(obj1 <= obj3, "obj1 should be <= obj3 (equal values)")

-- Test with >= operator (uses __le with swapped operands)
print("obj2 >= obj1:", obj2 >= obj1)
assert(obj2 >= obj1, "obj2 should be >= obj1")

print("__le test passed")
