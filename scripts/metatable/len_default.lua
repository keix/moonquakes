-- Test default length without __len metamethod
local obj = { 1, 2, 3, 4, 5 }
local mt = {}
setmetatable(obj, mt)

-- Should use default length (count sequential keys)
local result = #obj
print("default length:", result)
assert(result == 5, "expected 5, got " .. tostring(result))

-- String length (no metamethod for strings)
local str = "hello"
assert(#str == 5, "string length failed")
print("string length:", #str)

print("default length test passed")
