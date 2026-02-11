-- Simple tostring test
local t = {}
setmetatable(t, {__tostring = function() return "X" end})
local s = tostring(t)
print(s)
-- expect: X
