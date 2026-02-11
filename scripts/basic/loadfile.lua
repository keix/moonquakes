-- Test loadfile function

-- Basic: load file and execute
local fn = loadfile("scripts/basic/loadfile_helper.lua")
print("type: " .. type(fn))
-- expect: type: function

local result = fn()
print("result: " .. tostring(result))
-- expect: result: 123

-- Multiple return values
local multi_fn = loadfile("scripts/basic/loadfile_multi.lua")
local a, b, c = multi_fn()
print("multi: " .. a .. ", " .. b .. ", " .. c)
-- expect: multi: a, b, c

-- Load non-existent file returns nil and error
local bad_fn, err = loadfile("scripts/basic/nonexistent.lua")
print("bad fn: " .. tostring(bad_fn))
-- expect: bad fn: nil

-- Loaded function can be called multiple times
local fn2 = loadfile("scripts/basic/loadfile_helper.lua")
print("call1: " .. tostring(fn2()))
-- expect: call1: 123
print("call2: " .. tostring(fn2()))
-- expect: call2: 123

print("loadfile tests passed")
-- expect: loadfile tests passed
