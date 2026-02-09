-- Test rawget, rawset, rawlen, rawequal

-- Test rawget and rawset
local t = {}
rawset(t, "x", 42)
assert(rawget(t, "x") == 42, "rawget should return value set by rawset")

rawset(t, "y", "hello")
assert(rawget(t, "y") == "hello", "rawget should work with string values")

assert(rawget(t, "z") == nil, "rawget should return nil for missing keys")

-- Test rawlen with strings
assert(rawlen("hello") == 5, "rawlen('hello') should be 5")
assert(rawlen("") == 0, "rawlen('') should be 0")
assert(rawlen("abc") == 3, "rawlen('abc') should be 3")

-- Test rawlen with tables
local arr = {10, 20, 30}
assert(rawlen(arr) == 3, "rawlen({10,20,30}) should be 3")

local empty = {}
assert(rawlen(empty) == 0, "rawlen({}) should be 0")

-- Test rawequal
assert(rawequal(1, 1) == true, "rawequal(1, 1) should be true")
assert(rawequal(1, 2) == false, "rawequal(1, 2) should be false")
assert(rawequal("a", "a") == true, "rawequal('a', 'a') should be true")
assert(rawequal("a", "b") == false, "rawequal('a', 'b') should be false")
assert(rawequal(nil, nil) == true, "rawequal(nil, nil) should be true")
assert(rawequal(true, true) == true, "rawequal(true, true) should be true")
assert(rawequal(true, false) == false, "rawequal(true, false) should be false")

-- Tables are equal only if same reference
local t1 = {}
local t2 = {}
assert(rawequal(t1, t1) == true, "rawequal(t, t) should be true")
assert(rawequal(t1, t2) == false, "rawequal(t1, t2) should be false for different tables")

print("All raw function tests passed!")
