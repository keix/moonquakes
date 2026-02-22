-- v0.1.0 Release Test: Debug Library
-- Note: Variable names are not preserved (returns placeholders)

print("=== debug.getinfo ===")
local function testfn()
    return debug.getinfo(1)
end
local info = testfn()
assert(type(info) == "table")
assert(info.what == "Lua")

print("=== debug.traceback ===")
local tb = debug.traceback()
assert(type(tb) == "string")
assert(#tb > 0)

print("=== debug.getlocal ===")
local function test_local()
    local x = 42
    local name, value = debug.getlocal(1, 1)
    return value  -- name is placeholder, just check value
end
assert(test_local() == 42)

print("=== debug.setlocal ===")
local function test_setlocal()
    local x = 10
    debug.setlocal(1, 1, 99)
    return x
end
assert(test_setlocal() == 99)

print("=== debug.getupvalue ===")
local upval = 100
local function closure()
    return upval
end
-- upvalue[1] is _ENV, upvalue[2] is the captured variable
local name1, value1 = debug.getupvalue(closure, 1)
assert(name1 == "_ENV")  -- First upvalue is always _ENV
local name2, value2 = debug.getupvalue(closure, 2)
assert(value2 == 100)  -- Captured variable

print("=== debug.setupvalue ===")
debug.setupvalue(closure, 2, 200)  -- Set captured variable (index 2)
assert(closure() == 200)

print("=== debug.getmetatable/setmetatable ===")
local t = {}
local mt = {__index = function() return 42 end}
debug.setmetatable(t, mt)
assert(debug.getmetatable(t) == mt)

print("=== debug.getregistry ===")
local reg = debug.getregistry()
assert(type(reg) == "table")

print("[PASS] test_debug.lua")
