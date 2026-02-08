-- Test table.move

-- Move within same table
local t = {1, 2, 3, 4, 5}
table.move(t, 1, 3, 4)  -- Copy t[1..3] to t[4..6]
assert(t[1] == 1, "move same 1")
assert(t[2] == 2, "move same 2")
assert(t[3] == 3, "move same 3")
assert(t[4] == 1, "move same 4")
assert(t[5] == 2, "move same 5")
assert(t[6] == 3, "move same 6")

-- Move to different table
local src = {"a", "b", "c"}
local dst = {}
table.move(src, 1, 3, 1, dst)
assert(dst[1] == "a", "move to dst 1")
assert(dst[2] == "b", "move to dst 2")
assert(dst[3] == "c", "move to dst 3")

-- Move with offset
local src2 = {10, 20, 30, 40, 50}
local dst2 = {}
table.move(src2, 2, 4, 5, dst2)  -- Copy src[2..4] to dst[5..7]
assert(dst2[5] == 20, "move offset 5")
assert(dst2[6] == 30, "move offset 6")
assert(dst2[7] == 40, "move offset 7")

-- Return value is destination table
local t3 = {1, 2, 3}
local result = table.move(t3, 1, 2, 4)
assert(result == t3, "move returns dest table")

print("move passed")
