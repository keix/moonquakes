-- Test tonumber()

-- Numbers pass through unchanged
assert(tonumber(42) == 42, "tonumber(42) should be 42")
assert(tonumber(3.14) == 3.14, "tonumber(3.14) should be 3.14")

-- String to integer
assert(tonumber("123") == 123, "tonumber('123') should be 123")
assert(tonumber("-456") == -456, "tonumber('-456') should be -456")
assert(tonumber("0") == 0, "tonumber('0') should be 0")

-- String to float
assert(tonumber("3.14") == 3.14, "tonumber('3.14') should be 3.14")
assert(tonumber("-2.5") == -2.5, "tonumber('-2.5') should be -2.5")

-- With base (hex)
assert(tonumber("ff", 16) == 255, "tonumber('ff', 16) should be 255")
assert(tonumber("FF", 16) == 255, "tonumber('FF', 16) should be 255")
assert(tonumber("10", 16) == 16, "tonumber('10', 16) should be 16")

-- With base (binary)
assert(tonumber("1010", 2) == 10, "tonumber('1010', 2) should be 10")
assert(tonumber("1111", 2) == 15, "tonumber('1111', 2) should be 15")

-- With base (octal)
assert(tonumber("77", 8) == 63, "tonumber('77', 8) should be 63")

-- Invalid conversions return nil
assert(tonumber("abc") == nil, "tonumber('abc') should be nil")
assert(tonumber("") == nil, "tonumber('') should be nil")
assert(tonumber(nil) == nil, "tonumber(nil) should be nil")

print("All tonumber tests passed!")
