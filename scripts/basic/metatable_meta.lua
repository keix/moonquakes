-- Test __metatable metamethod

-- Basic __metatable - getmetatable returns the protected value
local t = {}
setmetatable(t, {
    __metatable = "protected"
})
print(getmetatable(t))
-- expect: protected

-- __metatable protects against setmetatable
local ok, err = pcall(function()
    setmetatable(t, {})
end)
print("protected: " .. tostring(not ok))
-- expect: protected: true

-- Without __metatable, getmetatable returns actual metatable
local t2 = {}
local mt = { __index = function() return 42 end }
setmetatable(t2, mt)
print(getmetatable(t2) == mt)
-- expect: true

-- Without __metatable, setmetatable works
setmetatable(t2, nil)
print(getmetatable(t2) == nil)
-- expect: true

print("__metatable tests passed")
-- expect: __metatable tests passed
