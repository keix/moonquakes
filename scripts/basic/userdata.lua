-- Userdata tests
-- Tests debug.newuserdata, debug.getuservalue, debug.setuservalue

-- Basic userdata creation
local u = debug.newuserdata(0)
assert(type(u) == "userdata", "newuserdata should return userdata")

-- Userdata with size
local u2 = debug.newuserdata(100)
assert(type(u2) == "userdata", "newuserdata(100) should return userdata")

-- Userdata with user values
local u3 = debug.newuserdata(0, 3)  -- 0 bytes, 3 user values
assert(type(u3) == "userdata", "newuserdata(0, 3) should return userdata")

-- Get/set user values
local val, exists = debug.getuservalue(u3, 1)
assert(val == nil, "initial user value should be nil")
assert(exists == true, "user value 1 should exist")

-- Set user value
debug.setuservalue(u3, "hello", 1)
local val2, exists2 = debug.getuservalue(u3, 1)
assert(val2 == "hello", "user value should be 'hello'")
assert(exists2 == true, "user value should exist")

-- Set different types
debug.setuservalue(u3, 42, 2)
debug.setuservalue(u3, {key = "value"}, 3)

local val3 = debug.getuservalue(u3, 2)
assert(val3 == 42, "user value 2 should be 42")

local val4 = debug.getuservalue(u3, 3)
assert(type(val4) == "table", "user value 3 should be table")
assert(val4.key == "value", "table should have key='value'")

-- Out of bounds access (1-indexed, so 0 and 4+ are invalid)
local val5, exists5 = debug.getuservalue(u3, 0)
assert(val5 == nil and exists5 == false, "index 0 should fail")

local val6, exists6 = debug.getuservalue(u3, 4)
assert(val6 == nil and exists6 == false, "index 4 should fail (only 3 user values)")

-- Set out of bounds (should return nil)
local result = debug.setuservalue(u3, "test", 5)
assert(result == nil, "setuservalue out of bounds should return nil")

-- Non-userdata access
local val7, exists7 = debug.getuservalue("not userdata", 1)
assert(val7 == nil and exists7 == false, "non-userdata should return nil, false")

-- Test that userdata survives GC
collectgarbage()
collectgarbage()
local val8 = debug.getuservalue(u3, 1)
assert(val8 == "hello", "user value should survive GC")

-- Test metatable
local mt = {__name = "TestUserdata"}
debug.setmetatable(u3, mt)
local mt2 = debug.getmetatable(u3)
assert(mt2 == mt, "metatable should be set")

print("userdata: PASSED")
