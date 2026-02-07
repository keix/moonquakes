-- Test __add metamethod
local mt = {
    __add = function(a, b)
        return { value = a.value + b.value }
    end
}

local t1 = { value = 10 }
local t2 = { value = 20 }
setmetatable(t1, mt)

-- This should trigger __add metamethod
local result = t1 + t2
assert(result.value == 30, "expected 30, got " .. tostring(result.value))

print("__add metamethod test passed")
