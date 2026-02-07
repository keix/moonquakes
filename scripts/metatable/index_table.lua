-- Test __index with table fallback
local defaults = { x = 10, y = 20 }
local mt = { __index = defaults }

local point = { z = 30 }
setmetatable(point, mt)

-- Direct access
assert(point.z == 30, "direct access failed")

-- Fallback to __index table
assert(point.x == 10, "expected x=10, got " .. tostring(point.x))
assert(point.y == 20, "expected y=20, got " .. tostring(point.y))

-- Non-existent key should still be nil
assert(point.w == nil, "non-existent key should be nil")

print("__index table test passed")
