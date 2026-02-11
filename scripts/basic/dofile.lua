-- Test dofile function

-- Basic: execute file and get result
local result = dofile("scripts/basic/loadfile_helper.lua")
print("result: " .. tostring(result))
-- expect: result: 123

-- Execute multiple times
local r1 = dofile("scripts/basic/loadfile_helper.lua")
local r2 = dofile("scripts/basic/loadfile_helper.lua")
print("twice: " .. tostring(r1) .. ", " .. tostring(r2))
-- expect: twice: 123, 123

print("dofile tests passed")
-- expect: dofile tests passed
