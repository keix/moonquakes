-- Test __index with function fallback
local mt = {
    __index = function(t, k)
        return "default_" .. k
    end
}

local obj = { name = "test" }
setmetatable(obj, mt)

-- Direct access
assert(obj.name == "test", "direct access failed")

-- Fallback to __index function
local result = obj.foo
assert(result == "default_foo", "expected default_foo, got " .. tostring(result))

print("__index function test passed")
