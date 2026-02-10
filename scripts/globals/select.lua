-- Test select()

-- Test "#" returns count
assert(select("#") == 0, "select('#') with no args should be 0")
assert(select("#", 1) == 1, "select('#', 1) should be 1")
assert(select("#", 1, 2, 3) == 3, "select('#', 1, 2, 3) should be 3")
assert(select("#", "a", "b", "c", "d", "e") == 5, "select('#', ...) should be 5")

-- Test positive index
local a = select(1, 10, 20, 30)
assert(a == 10, "select(1, 10, 20, 30) first result should be 10")

local b = select(2, 10, 20, 30)
assert(b == 20, "select(2, 10, 20, 30) first result should be 20")

local c = select(3, 10, 20, 30)
assert(c == 30, "select(3, 10, 20, 30) first result should be 30")

-- Test multiple returns
local x, y, z = select(1, 100, 200, 300)
assert(x == 100, "x should be 100")
assert(y == 200, "y should be 200")
assert(z == 300, "z should be 300")

local p, q = select(2, 100, 200, 300)
assert(p == 200, "p should be 200")
assert(q == 300, "q should be 300")

-- Test out of range
local nil_val = select(10, 1, 2, 3)
assert(nil_val == nil, "select(10, 1, 2, 3) should be nil")

print("All select tests passed!")
