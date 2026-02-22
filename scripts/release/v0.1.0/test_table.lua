-- v0.1.0 Release Test: Table Library

print("=== table.insert ===")
local t = {1, 2, 3}
table.insert(t, 4)
assert(t[4] == 4)
table.insert(t, 2, 10)
assert(t[2] == 10 and t[3] == 2)

print("=== table.remove ===")
local t2 = {1, 2, 3, 4}
local removed = table.remove(t2)
assert(removed == 4 and #t2 == 3)
local removed2 = table.remove(t2, 1)
assert(removed2 == 1 and t2[1] == 2)

print("=== table.concat ===")
local t3 = {"a", "b", "c"}
assert(table.concat(t3) == "abc")
assert(table.concat(t3, ",") == "a,b,c")
assert(table.concat(t3, ",", 2) == "b,c")
assert(table.concat(t3, ",", 2, 3) == "b,c")

print("=== table.sort ===")
local t4 = {3, 1, 4, 1, 5, 9, 2, 6}
table.sort(t4)
assert(t4[1] == 1 and t4[2] == 1 and t4[8] == 9)

local t5 = {3, 1, 4}
table.sort(t5, function(a, b) return a > b end)
assert(t5[1] == 4 and t5[3] == 1)

print("=== table.unpack ===")
local a, b, c = table.unpack({10, 20, 30})
assert(a == 10 and b == 20 and c == 30)

local x, y = table.unpack({1, 2, 3, 4}, 2, 3)
assert(x == 2 and y == 3)

print("=== table.pack ===")
local packed = table.pack(1, 2, 3)
assert(packed.n == 3)
assert(packed[1] == 1 and packed[2] == 2)

print("=== table.move ===")
local src = {1, 2, 3, 4, 5}
local dst = {}
table.move(src, 2, 4, 1, dst)
assert(dst[1] == 2 and dst[2] == 3 and dst[3] == 4)

print("[PASS] test_table.lua")
