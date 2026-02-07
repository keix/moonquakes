-- Simple __concat test
local mt = {
    __concat = function(a, b)
        return "[" .. tostring(a) .. "+" .. tostring(b) .. "]"
    end
}

local obj = { value = 42 }
setmetatable(obj, mt)

-- obj .. "test" should call __concat(obj, "test")
local result = obj .. "test"
print("result:", result)
assert(result == "[<table>+test]", "expected [<table>+test], got " .. tostring(result))

-- "hello" .. obj should call __concat("hello", obj)
local result2 = "hello" .. obj
print("result2:", result2)
assert(result2 == "[hello+<table>]", "expected [hello+<table>], got " .. tostring(result2))

print("__concat test passed")
