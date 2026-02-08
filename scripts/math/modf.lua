-- Test modf (integer and fractional parts)
local eps = 1e-10

local i, f = math.modf(3.75)
assert(i == 3, "modf(3.75) integer part should be 3")
assert(math.abs(f - 0.75) < eps, "modf(3.75) fractional part should be 0.75")

local i2, f2 = math.modf(-5.25)
assert(i2 == -5, "modf(-5.25) integer part should be -5")
assert(math.abs(f2 - (-0.25)) < eps, "modf(-5.25) fractional part should be -0.25")

local i3, f3 = math.modf(7)
assert(i3 == 7, "modf(7) integer part should be 7")
assert(math.abs(f3) < eps, "modf(7) fractional part should be 0")

print("modf passed")
