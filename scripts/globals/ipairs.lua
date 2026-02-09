-- Test ipairs()

-- Test with array-like table
local arr = {10, 20, 30, 40, 50}

-- Test ipairs returns iterator, table, 0
local iter, tbl, init = ipairs(arr)
assert(type(iter) == "function", "ipairs should return function as first value")
assert(type(tbl) == "table", "ipairs should return table as second value")
assert(init == 0, "ipairs should return 0 as third value")

-- Use ipairs iterator manually
local sum = 0
local count = 0
local i, v = iter(tbl, 0)
while i do
    count = count + 1
    sum = sum + v
    i, v = iter(tbl, i)
end

assert(count == 5, "should iterate 5 times")
assert(sum == 150, "sum should be 150")

-- Test with gaps (ipairs should stop at first nil)
local sparse = {1, 2, nil, 4, 5}
count = 0
i, v = ipairs(sparse)
local idx, val = i(v, 0)
while idx do
    count = count + 1
    idx, val = i(v, idx)
end

-- Should stop at first nil (after index 2)
assert(count == 2, "should stop at first nil")

-- Test empty array
local empty = {}
i, tbl, init = ipairs(empty)
idx, val = i(tbl, init)
assert(idx == nil, "empty array should return nil immediately")

print("All ipairs tests passed!")
