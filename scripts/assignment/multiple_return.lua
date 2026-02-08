-- Test multiple return value assignment

-- Helper function that returns multiple values
function getThree()
    return 1, 2, 3
end

function getTwo()
    return 10, 20
end

-- Test 1: Local multiple assignment from function
local a, b, c = getThree()
assert(a == 1, "a should be 1")
assert(b == 2, "b should be 2")
assert(c == 3, "c should be 3")

-- Test 2: Global multiple assignment from function
g1, g2, g3 = getThree()
assert(g1 == 1, "g1 should be 1")
assert(g2 == 2, "g2 should be 2")
assert(g3 == 3, "g3 should be 3")

-- Test 3: Fewer variables than return values
local x, y = getThree()
assert(x == 1, "x should be 1")
assert(y == 2, "y should be 2")

-- Test 4: More variables than return values (extra get nil)
local p, q, r, s = getTwo()
assert(p == 10, "p should be 10")
assert(q == 20, "q should be 20")
assert(r == nil, "r should be nil")
assert(s == nil, "s should be nil")

-- Test 5: Multiple expressions (not function call)
local m, n, o = 100, 200, 300
assert(m == 100, "m should be 100")
assert(n == 200, "n should be 200")
assert(o == 300, "o should be 300")

-- Test 6: Global multiple expressions
h1, h2 = 42, 84
assert(h1 == 42, "h1 should be 42")
assert(h2 == 84, "h2 should be 84")

-- Test 7: Fewer expressions than variables
local i, j, k = 1, 2
assert(i == 1, "i should be 1")
assert(j == 2, "j should be 2")
assert(k == nil, "k should be nil")

print("All multiple return value tests passed!")
