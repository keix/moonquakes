-- Simple __eq test
local mt = {
    __eq = function(a, b)
        -- Compare by 'id' field
        return a.id == b.id
    end
}

local obj1 = { id = 1, name = "first" }
local obj2 = { id = 1, name = "second" }
local obj3 = { id = 2, name = "third" }

setmetatable(obj1, mt)
setmetatable(obj2, mt)
setmetatable(obj3, mt)

-- obj1 and obj2 have same id, should be equal
print("obj1 == obj2:", obj1 == obj2)
assert(obj1 == obj2, "obj1 and obj2 should be equal (same id)")

-- obj1 and obj3 have different id, should not be equal
print("obj1 == obj3:", obj1 == obj3)
assert(not (obj1 == obj3), "obj1 and obj3 should not be equal (different id)")

-- Same object should be equal (no metamethod needed)
print("obj1 == obj1:", obj1 == obj1)
assert(obj1 == obj1, "obj1 should equal itself")

print("__eq test passed")
