-- Test basic debug library functions
-- debug is a global table, not require-able

-- Test 1: debug.getmetatable / debug.setmetatable
print("Test 1: debug.getmetatable / debug.setmetatable")

local mt = {__metatable = "protected"}
local t = setmetatable({}, mt)

-- Standard getmetatable returns protected value
assert(getmetatable(t) == "protected", "getmetatable should return __metatable value")

-- debug.getmetatable bypasses protection
local raw_mt = debug.getmetatable(t)
assert(raw_mt == mt, "debug.getmetatable should return raw metatable")
assert(raw_mt.__metatable == "protected", "raw metatable should have __metatable field")

-- debug.setmetatable bypasses protection
local new_mt = {foo = "bar"}
debug.setmetatable(t, new_mt)
assert(debug.getmetatable(t) == new_mt, "debug.setmetatable should set new metatable")
assert(debug.getmetatable(t).foo == "bar", "new metatable should have foo field")

-- Set metatable to nil
debug.setmetatable(t, nil)
assert(debug.getmetatable(t) == nil, "debug.setmetatable(t, nil) should remove metatable")

print("  Test 1 PASSED")

-- Test 2: debug.getupvalue / debug.setupvalue
print("Test 2: debug.getupvalue / debug.setupvalue")

local x = 10
local y = 20

local function foo()
    return x + y
end

-- Test getupvalue
local name1, val1 = debug.getupvalue(foo, 1)
local name2, val2 = debug.getupvalue(foo, 2)

-- Upvalue names might be x and y (order may vary)
assert(name1 ~= nil, "getupvalue should return name")
assert(val1 == 10 or val1 == 20, "getupvalue should return value")
assert(name2 ~= nil, "getupvalue for second upvalue should return name")
assert(val2 == 10 or val2 == 20, "getupvalue for second upvalue should return value")

-- Test getupvalue out of bounds
local name3 = debug.getupvalue(foo, 3)
assert(name3 == nil, "getupvalue out of bounds should return nil")

-- Test setupvalue
debug.setupvalue(foo, 1, 100)
local _, newval = debug.getupvalue(foo, 1)
assert(newval == 100, "setupvalue should change upvalue value")

-- Verify the actual variable was changed
assert(x == 100 or y == 100, "setupvalue should affect original variable")

print("  Test 2 PASSED")

-- Test 3: edge cases
print("Test 3: Edge cases")

-- getmetatable on non-table
assert(debug.getmetatable(42) == nil, "getmetatable on number should return nil")
assert(debug.getmetatable("str") == nil, "getmetatable on string should return nil")

-- getupvalue on non-function
assert(debug.getupvalue({}, 1) == nil, "getupvalue on table should return nil")

-- getupvalue with invalid index
assert(debug.getupvalue(foo, 0) == nil, "getupvalue with index 0 should return nil")
assert(debug.getupvalue(foo, -1) == nil, "getupvalue with negative index should return nil")

print("  Test 3 PASSED")

-- Test 4: debug.traceback
print("Test 4: debug.traceback")

-- Use explicit locals to prevent tail call optimization
local function level3()
    local t = debug.traceback()
    return t
end

local function level2()
    local r = level3()
    return r
end

local function level1()
    local r = level2()
    return r
end

local trace = level1()
assert(type(trace) == "string", "traceback should return string")
assert(string.find(trace, "stack traceback:"), "traceback should contain 'stack traceback:'")
assert(string.find(trace, "Lua function"), "traceback should mention Lua function")

-- Test with message
local trace2 = debug.traceback("my error message")
assert(string.find(trace2, "my error message"), "traceback should include message")

-- Test with level
local trace3 = debug.traceback(nil, 2)
-- Level 2 skips some frames

print("  Traceback sample:")
print(trace)
print("  Test 4 PASSED")

print("")
print("=== All debug tests PASSED ===")
