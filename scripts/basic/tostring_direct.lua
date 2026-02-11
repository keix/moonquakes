-- Direct tostring test
local t = {}
setmetatable(t, {__tostring = function() return "X" end})
print(tostring(t))
-- expect: X
