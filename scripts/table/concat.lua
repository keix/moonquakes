-- Test table.concat

-- Basic concatenation
local t = {"a", "b", "c"}
assert(table.concat(t) == "abc", "concat no separator")

-- With separator
assert(table.concat(t, ",") == "a,b,c", "concat with comma")
assert(table.concat(t, " - ") == "a - b - c", "concat with long separator")

-- With numbers
local nums = {1, 2, 3}
assert(table.concat(nums, "+") == "1+2+3", "concat numbers")

-- Mixed strings and numbers
local mixed = {"a", 1, "b", 2}
assert(table.concat(mixed, ":") == "a:1:b:2", "concat mixed")

-- With start and end indices
local t2 = {"a", "b", "c", "d", "e"}
assert(table.concat(t2, ",", 2) == "b,c,d,e", "concat with start")
assert(table.concat(t2, ",", 2, 4) == "b,c,d", "concat with start and end")
assert(table.concat(t2, ",", 3, 3) == "c", "concat single element")

-- Empty result
assert(table.concat(t2, ",", 5, 4) == "", "concat empty range")
assert(table.concat({}) == "", "concat empty table")

print("concat passed")
