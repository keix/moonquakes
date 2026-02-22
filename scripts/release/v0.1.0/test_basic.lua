-- v0.1.0 Release Test: Basic Functions
-- Tests: type, tonumber, tostring, select, raw*, pairs/ipairs, metatable, pcall/xpcall, assert, collectgarbage

print("=== type() ===")
assert(type(nil) == "nil")
assert(type(true) == "boolean")
assert(type(1) == "number")
assert(type(1.5) == "number")
assert(type("hello") == "string")
assert(type({}) == "table")
assert(type(print) == "function")

print("=== tonumber() ===")
assert(tonumber("123") == 123)
assert(tonumber("12.5") == 12.5)
assert(tonumber("0xff") == 255)
assert(tonumber("abc") == nil)
assert(tonumber(123) == 123)
assert(tonumber("1010", 2) == 10)
assert(tonumber("ff", 16) == 255)

print("=== tostring() ===")
assert(tostring(123) == "123")
assert(tostring(true) == "true")
assert(tostring(nil) == "nil")

print("=== select() ===")
assert(select("#", 1, 2, 3) == 3)
assert(select(1, "a", "b", "c") == "a")
assert(select(2, "a", "b", "c") == "b")
assert(select(-1, "a", "b", "c") == "c")

print("=== raw* functions ===")
local t = {a = 1, b = 2}
assert(rawget(t, "a") == 1)
rawset(t, "c", 3)
assert(t.c == 3)
assert(rawlen({1,2,3}) == 3)
assert(rawequal(t, t) == true)
assert(rawequal({}, {}) == false)

print("=== pairs/ipairs ===")
local arr = {10, 20, 30}
local sum = 0
for i, v in ipairs(arr) do sum = sum + v end
assert(sum == 60)

print("=== metatable ===")
local mt = {__index = function() return 42 end}
local obj = setmetatable({}, mt)
assert(getmetatable(obj) == mt)
assert(obj.anything == 42)

print("=== pcall/xpcall ===")
local ok, err = pcall(function() error("test error") end)
assert(ok == false, "pcall should return false on error")
assert(type(err) == "string", "pcall should return error message")
local ok2 = pcall(function() return 1 end)
assert(ok2 == true, "pcall should return true on success")

print("=== assert ===")
assert(assert(true) == true)
assert(assert(1) == 1)
local ok3 = pcall(function() assert(false, "expected failure") end)
assert(ok3 == false, "pcall of failed assert should return false")

print("=== collectgarbage ===")
assert(type(collectgarbage("count")) == "number")

print("[PASS] test_basic.lua")
