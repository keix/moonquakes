-- v0.1.0 Release Test: OS Library

print("=== os.time ===")
local t = os.time()
assert(type(t) == "number" and t > 0)

print("=== os.date ===")
local d = os.date("*t")
assert(type(d) == "table")
assert(d.year >= 2024)
assert(d.month >= 1 and d.month <= 12)
assert(d.day >= 1 and d.day <= 31)

local formatted = os.date("%Y-%m-%d")
assert(#formatted == 10)

print("=== os.difftime ===")
local t1 = os.time()
local t2 = t1 + 100
assert(os.difftime(t2, t1) == 100)

print("=== os.clock ===")
local c = os.clock()
assert(type(c) == "number")

print("=== os.getenv ===")
local path = os.getenv("PATH")
assert(path ~= nil)
local nonexistent = os.getenv("NONEXISTENT_VAR_12345")
assert(nonexistent == nil)

print("=== os.tmpname ===")
local tmp = os.tmpname()
assert(type(tmp) == "string" and #tmp > 0)

print("=== os.execute ===")
local ok = os.execute("true")
assert(ok == true)

print("=== os.rename/remove ===")
local f = io.open("/tmp/moonquakes_test_rename.txt", "w")
f:write("test")
f:close()
local ok2, err = os.rename("/tmp/moonquakes_test_rename.txt", "/tmp/moonquakes_test_renamed.txt")
assert(ok2 == true)
local ok3 = os.remove("/tmp/moonquakes_test_renamed.txt")
assert(ok3 == true)

print("=== os.setlocale ===")
local loc = os.setlocale(nil)
assert(type(loc) == "string")

print("[PASS] test_os.lua")
