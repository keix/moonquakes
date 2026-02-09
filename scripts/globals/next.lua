-- Test next()

-- Test with table
local t = {x = 10, y = 20, z = 30}

-- Collect all keys using next
local keys = {}
local count = 0
local k = next(t, nil)
while k do
    count = count + 1
    keys[count] = k
    k = next(t, k)
end

assert(count == 3, "should find 3 keys")

-- Verify all keys were found (order may vary)
local found_x = false
local found_y = false
local found_z = false
local i = 1
while i <= count do
    if keys[i] == "x" then found_x = true end
    if keys[i] == "y" then found_y = true end
    if keys[i] == "z" then found_z = true end
    i = i + 1
end
assert(found_x, "should find key 'x'")
assert(found_y, "should find key 'y'")
assert(found_z, "should find key 'z'")

-- Test empty table
local empty = {}
assert(next(empty) == nil, "next on empty table should be nil")

-- Test next with value
local k2, v2 = next(t, nil)
assert(k2, "first key should not be nil")
assert(v2, "first value should not be nil")

print("All next tests passed!")
