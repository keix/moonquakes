-- Test fmod (floating point remainder)
local eps = 1e-10

assert(math.abs(math.fmod(10, 3) - 1) < eps, "fmod(10, 3) should be 1")
assert(math.abs(math.fmod(10.5, 3) - 1.5) < eps, "fmod(10.5, 3) should be 1.5")
assert(math.abs(math.fmod(-10, 3) - (-1)) < eps, "fmod(-10, 3) should be -1")
assert(math.abs(math.fmod(10, -3) - 1) < eps, "fmod(10, -3) should be 1")

print("fmod passed")
