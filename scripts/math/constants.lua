-- Test math constants
assert(math.pi > 3.14 and math.pi < 3.15, "math.pi incorrect")
assert(math.huge > 1e308, "math.huge should be infinity")
assert(math.maxinteger == 9223372036854775807, "math.maxinteger incorrect")
assert(math.mininteger == -9223372036854775808, "math.mininteger incorrect")
print("constants passed")
