-- Test io.type()

-- Non-file values should return nil
assert(io.type(nil) == nil, "io.type(nil) should be nil")
assert(io.type(123) == nil, "io.type(number) should be nil")
assert(io.type("string") == nil, "io.type(string) should be nil")
assert(io.type({}) == nil, "io.type(empty table) should be nil")
assert(io.type(print) == nil, "io.type(function) should be nil")

-- Open file should return "file"
local f = io.open("scripts/io/io_type.lua", "r")
assert(f, "io.open should succeed")
assert(io.type(f) == "file", "io.type(open file) should be 'file'")

-- Closed file should return "closed file"
f:close()
assert(io.type(f) == "closed file", "io.type(closed file) should be 'closed file'")

print("All io.type tests passed!")
