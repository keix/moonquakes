-- Test min/max functions
assert(math.max(1, 5, 3) == 5, "max(1,5,3) should be 5")
assert(math.max(-1, -5, -3) == -1, "max(-1,-5,-3) should be -1")
assert(math.max(3.5, 2.5, 4.5) == 4.5, "max(3.5,2.5,4.5) should be 4.5")

assert(math.min(1, 5, 3) == 1, "min(1,5,3) should be 1")
assert(math.min(-1, -5, -3) == -5, "min(-1,-5,-3) should be -5")
assert(math.min(3.5, 2.5, 4.5) == 2.5, "min(3.5,2.5,4.5) should be 2.5")

-- single argument
assert(math.max(42) == 42, "max(42) should be 42")
assert(math.min(42) == 42, "min(42) should be 42")

print("minmax passed")
