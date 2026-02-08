-- Test math.ult (unsigned less than)
assert(math.ult(1, 2) == true, "ult(1, 2) should be true")
assert(math.ult(2, 1) == false, "ult(2, 1) should be false")
assert(math.ult(1, 1) == false, "ult(1, 1) should be false")

-- -1 as unsigned is max value, so -1 > 1 in unsigned comparison
assert(math.ult(-1, 1) == false, "ult(-1, 1) should be false (unsigned)")
assert(math.ult(1, -1) == true, "ult(1, -1) should be true (unsigned)")

print("ult passed")
