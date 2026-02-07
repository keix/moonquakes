-- Test __le fallback to __lt (a <= b iff not (b < a))
local mt = {
    -- Only define __lt, not __le
    __lt = function(a, b)
        return a.value < b.value
    end
}

local obj1 = { value = 10 }
local obj2 = { value = 20 }
local obj3 = { value = 10 }

setmetatable(obj1, mt)
setmetatable(obj2, mt)
setmetatable(obj3, mt)

-- obj1 <= obj2 should be true (10 <= 20, via !(20 < 10))
print("obj1 <= obj2:", obj1 <= obj2)
assert(obj1 <= obj2, "obj1 should be <= obj2")

-- obj2 <= obj1 should be false (20 <= 10, via !(10 < 20) = !true = false)
print("obj2 <= obj1:", obj2 <= obj1)
assert(not (obj2 <= obj1), "obj2 should not be <= obj1")

-- obj1 <= obj3 should be true (10 <= 10, via !(10 < 10) = !false = true)
print("obj1 <= obj3:", obj1 <= obj3)
assert(obj1 <= obj3, "obj1 should be <= obj3 (equal values)")

print("__le fallback to __lt test passed")
