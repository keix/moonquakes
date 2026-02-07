-- Test default concat without __concat metamethod
local str1 = "hello"
local str2 = "world"
local num = 42

-- String concat
local result1 = str1 .. " " .. str2
print("result1:", result1)
assert(result1 == "hello world", "string concat failed")

-- String + number concat
local result2 = "value: " .. num
print("result2:", result2)
assert(result2 == "value: 42", "string+number concat failed")

print("default concat test passed")
