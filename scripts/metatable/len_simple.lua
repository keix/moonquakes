-- Simple __len test
local mt = {
    __len = function(self)
        return 42
    end
}

local obj = { 1, 2, 3 }
setmetatable(obj, mt)

local result = #obj
print("result:", result)
assert(result == 42, "expected 42, got " .. tostring(result))
print("__len test passed")
