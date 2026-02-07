-- Basic metatable test
local t = {}
local mt = { __metatable = "protected" }
setmetatable(t, mt)

-- getmetatable returns __metatable value when set
local result = getmetatable(t)
assert(result == "protected", "expected 'protected', got " .. tostring(result))

print("metatable basic test passed")
