-- Test random and randomseed
math.randomseed(12345)

-- No args: returns [0, 1)
local r1 = math.random()
assert(r1 >= 0 and r1 < 1, "random() should be in [0, 1)")

-- One arg: returns [1, m]
local r2 = math.random(10)
assert(r2 >= 1 and r2 <= 10, "random(10) should be in [1, 10]")
assert(math.type(r2) == "integer", "random(10) should return integer")

-- Two args: returns [m, n]
local r3 = math.random(5, 15)
assert(r3 >= 5 and r3 <= 15, "random(5, 15) should be in [5, 15]")
assert(math.type(r3) == "integer", "random(5, 15) should return integer")

-- Same seed produces same sequence
math.randomseed(42)
local a1 = math.random()
local a2 = math.random(100)

math.randomseed(42)
local b1 = math.random()
local b2 = math.random(100)

assert(a1 == b1, "same seed should produce same sequence")
assert(a2 == b2, "same seed should produce same sequence")

print("random passed")
