-- Test exponential and logarithmic functions
local eps = 1e-10

-- exp
assert(math.abs(math.exp(0) - 1) < eps, "exp(0) should be 1")
assert(math.abs(math.exp(1) - 2.718281828) < 1e-6, "exp(1) should be e")

-- log (natural)
assert(math.abs(math.log(1)) < eps, "log(1) should be 0")
assert(math.abs(math.log(math.exp(1)) - 1) < eps, "log(e) should be 1")

-- log with base
assert(math.abs(math.log(8, 2) - 3) < eps, "log(8, 2) should be 3")
assert(math.abs(math.log(1000, 10) - 3) < eps, "log(1000, 10) should be 3")

-- deg/rad conversion
assert(math.abs(math.deg(math.pi) - 180) < eps, "deg(pi) should be 180")
assert(math.abs(math.deg(math.pi/2) - 90) < eps, "deg(pi/2) should be 90")
assert(math.abs(math.rad(180) - math.pi) < eps, "rad(180) should be pi")
assert(math.abs(math.rad(90) - math.pi/2) < eps, "rad(90) should be pi/2")

print("exp_log passed")
