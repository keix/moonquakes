-- Test math.type and math.tointeger
assert(math.type(42) == "integer", "type(42) should be 'integer'")
assert(math.type(3.14) == "float", "type(3.14) should be 'float'")
assert(math.type(3.0) == "float", "type(3.0) should be 'float'")
assert(math.type("hello") == nil, "type('hello') should be nil")
assert(math.type(nil) == nil, "type(nil) should be nil")

-- tointeger
assert(math.tointeger(42) == 42, "tointeger(42) should be 42")
assert(math.tointeger(3.0) == 3, "tointeger(3.0) should be 3")
assert(math.tointeger(3.5) == nil, "tointeger(3.5) should be nil")
assert(math.tointeger("hello") == nil, "tointeger('hello') should be nil")

print("type passed")
