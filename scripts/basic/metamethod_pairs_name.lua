-- Test __pairs and __name metamethods

-- Test __pairs metamethod
local pairs_called = false
local t = setmetatable({x=10, y=20}, {
    __pairs = function(tbl)
        pairs_called = true
        return next, tbl, nil
    end
})

local count = 0
for k, v in pairs(t) do
    count = count + 1
end
assert(pairs_called, "__pairs was not called")
assert(count == 2, "Expected 2 iterations")

-- Test __name metamethod
local MyClass = {}
MyClass.__index = MyClass
MyClass.__name = "MyClass"

local obj = setmetatable({}, MyClass)
assert(type(obj) == "MyClass", "type() should return __name value")

-- Verify default type() behavior
assert(type(nil) == "nil")
assert(type(true) == "boolean")
assert(type(42) == "number")
assert(type(3.14) == "number")
assert(type("hello") == "string")
assert(type({}) == "table")
assert(type(print) == "function")

print("metamethod_pairs_name: PASSED")
