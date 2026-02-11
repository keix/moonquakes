-- Test pcall

-- Success case
local ok, result = pcall(function() return 42 end)
print("success: " .. tostring(ok) .. ", " .. tostring(result))
-- expect: success: true, 42

-- Error case
local ok2, err = pcall(function() error("test error") end)
print("error: " .. tostring(ok2) .. ", " .. tostring(err))
-- expect: error: false, test error

-- With arguments
local ok3, result3 = pcall(function(a, b) return a + b end, 10, 20)
print("args: " .. tostring(ok3) .. ", " .. tostring(result3))
-- expect: args: true, 30

-- No function provided
local ok4, err4 = pcall()
print("no func: " .. tostring(ok4))
-- expect: no func: false
