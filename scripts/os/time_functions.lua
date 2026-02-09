-- Test os.clock, os.time, os.getenv, os.difftime

-- os.clock should return a number
local clock = os.clock()
assert(type(clock) == "number", "os.clock() should return a number")
assert(clock > 0, "os.clock() should be positive")

-- os.time should return an integer (Unix timestamp)
local time = os.time()
assert(type(time) == "number", "os.time() should return a number")
assert(time > 1700000000, "os.time() should be a recent timestamp")

-- os.getenv should return string for existing vars
local home = os.getenv("HOME")
assert(home, "os.getenv('HOME') should not be nil")
assert(type(home) == "string", "os.getenv should return a string")

-- os.getenv should return nil for non-existent vars
local nonexistent = os.getenv("THIS_VAR_DOES_NOT_EXIST_12345")
assert(nonexistent == nil, "os.getenv for non-existent var should be nil")

-- os.difftime should return the difference
local t1 = 1000
local t2 = 1500
assert(os.difftime(t2, t1) == 500, "os.difftime(1500, 1000) should be 500")
assert(os.difftime(t1, t2) == -500, "os.difftime(1000, 1500) should be -500")
assert(os.difftime(t1, t1) == 0, "os.difftime(t, t) should be 0")

print("All os time function tests passed!")
