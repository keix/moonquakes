-- Test __newindex with function fallback
local call_count = 0
local mt = {
    __newindex = function(t, k, v)
        call_count = call_count + 1
        print("newindex called:", k, v)
    end
}

local obj = { name = "test" }
setmetatable(obj, mt)

-- Updating existing key should work directly
obj.name = "updated"
assert(obj.name == "updated", "existing key update failed")
assert(call_count == 0, "newindex should not be called for existing key")

-- Setting new key should call __newindex function
obj.foo = "bar"
assert(call_count == 1, "expected 1 call")

print("__newindex function test passed")
