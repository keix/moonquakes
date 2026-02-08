-- Test basic math functions: abs, sqrt, floor, ceil
assert(math.abs(-5) == 5, "abs(-5) should be 5")
assert(math.abs(5) == 5, "abs(5) should be 5")
assert(math.abs(-3.5) == 3.5, "abs(-3.5) should be 3.5")

assert(math.sqrt(16) == 4, "sqrt(16) should be 4")
assert(math.sqrt(2) > 1.41 and math.sqrt(2) < 1.42, "sqrt(2) should be ~1.414")

assert(math.floor(3.7) == 3, "floor(3.7) should be 3")
assert(math.floor(-3.7) == -4, "floor(-3.7) should be -4")
assert(math.floor(5) == 5, "floor(5) should be 5")

assert(math.ceil(3.2) == 4, "ceil(3.2) should be 4")
assert(math.ceil(-3.2) == -3, "ceil(-3.2) should be -3")
assert(math.ceil(5) == 5, "ceil(5) should be 5")

print("basic passed")
