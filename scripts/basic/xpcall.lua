-- Test xpcall

-- Success case
local ok, result = xpcall(function() return 42 end, function(e) return e end)
print("success: " .. tostring(ok) .. ", " .. tostring(result))
-- expect: success: true, 42

-- Error case with handler
local ok2, result2 = xpcall(
    function() error("original error") end,
    function(e) return e end
)
print("error ok: " .. tostring(ok2))
print("error msg: " .. tostring(result2))
-- expect: error ok: false
-- expect: error msg: original error

-- With arguments
local ok3, result3 = xpcall(
    function(a, b) return a * b end,
    function(e) return e end,
    5, 6
)
print("args: " .. tostring(ok3) .. ", " .. tostring(result3))
-- expect: args: true, 30
