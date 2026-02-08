-- Test table.sort

-- Sort numbers ascending
local nums = {5, 2, 8, 1, 9, 3}
table.sort(nums)
assert(nums[1] == 1, "sort nums 1")
assert(nums[2] == 2, "sort nums 2")
assert(nums[3] == 3, "sort nums 3")
assert(nums[4] == 5, "sort nums 4")
assert(nums[5] == 8, "sort nums 5")
assert(nums[6] == 9, "sort nums 6")

-- Sort strings
local strs = {"banana", "apple", "cherry"}
table.sort(strs)
assert(strs[1] == "apple", "sort strs 1")
assert(strs[2] == "banana", "sort strs 2")
assert(strs[3] == "cherry", "sort strs 3")

-- Sort already sorted
local sorted = {1, 2, 3}
table.sort(sorted)
assert(sorted[1] == 1, "already sorted 1")
assert(sorted[2] == 2, "already sorted 2")
assert(sorted[3] == 3, "already sorted 3")

-- Sort reverse order
local rev = {3, 2, 1}
table.sort(rev)
assert(rev[1] == 1, "reverse 1")
assert(rev[2] == 2, "reverse 2")
assert(rev[3] == 3, "reverse 3")

-- Sort single element
local single = {42}
table.sort(single)
assert(single[1] == 42, "single element")

-- Sort empty table
local empty = {}
table.sort(empty)
-- No assertion needed, just shouldn't crash

print("sort passed")
