-- Test pairs()

-- Test with table containing string keys
local t = {a = 1, b = 2, c = 3}

-- Collect all key-value pairs
local keys = {}
local values = {}
local count = 0

local k, v = next(t, nil)
while k do
    count = count + 1
    keys[count] = k
    values[count] = v
    k, v = next(t, k)
end

assert(count == 3, "should find 3 pairs")

-- Test pairs returns next, table, nil
local iter, tbl, init = pairs(t)
assert(type(iter) == "function", "pairs should return function as first value")
assert(type(tbl) == "table", "pairs should return table as second value")
assert(init == nil, "pairs should return nil as third value")

-- Use pairs in manual iteration
local count2 = 0
k, v = iter(tbl, nil)
while k do
    count2 = count2 + 1
    k, v = iter(tbl, k)
end

assert(count2 == 3, "manual pairs iteration should find 3 pairs")

print("All pairs tests passed!")
