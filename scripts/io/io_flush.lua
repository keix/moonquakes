-- Test io.flush()

-- io.flush should return true
local result = io.flush()
assert(result == true, "io.flush() should return true")

-- Can be called multiple times
assert(io.flush() == true, "io.flush() should be callable multiple times")

print("All io.flush tests passed!")
