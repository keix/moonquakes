-- Test trigonometric functions
local eps = 1e-10

assert(math.abs(math.sin(0)) < eps, "sin(0) should be 0")
assert(math.abs(math.sin(math.pi/2) - 1) < eps, "sin(pi/2) should be 1")
assert(math.abs(math.sin(math.pi)) < eps, "sin(pi) should be 0")

assert(math.abs(math.cos(0) - 1) < eps, "cos(0) should be 1")
assert(math.abs(math.cos(math.pi/2)) < eps, "cos(pi/2) should be 0")
assert(math.abs(math.cos(math.pi) + 1) < eps, "cos(pi) should be -1")

assert(math.abs(math.tan(0)) < eps, "tan(0) should be 0")
assert(math.abs(math.tan(math.pi/4) - 1) < eps, "tan(pi/4) should be 1")

assert(math.abs(math.asin(0)) < eps, "asin(0) should be 0")
assert(math.abs(math.asin(1) - math.pi/2) < eps, "asin(1) should be pi/2")

assert(math.abs(math.acos(1)) < eps, "acos(1) should be 0")
assert(math.abs(math.acos(0) - math.pi/2) < eps, "acos(0) should be pi/2")

assert(math.abs(math.atan(0)) < eps, "atan(0) should be 0")
assert(math.abs(math.atan(1) - math.pi/4) < eps, "atan(1) should be pi/4")
assert(math.abs(math.atan(1, 1) - math.pi/4) < eps, "atan(1,1) should be pi/4")

print("trig passed")
