-- Test integer keys vs string keys in tables

-- Test 1: Array-style table uses integer keys
local t = {10, 20, 30}
assert(#t == 3, "length should be 3")
assert(type(t[1]) == "number", "t[1] should exist")
assert(t[1] == 10, "t[1] should be 10")
assert(t[2] == 20, "t[2] should be 20")
assert(t[3] == 30, "t[3] should be 30")

-- Test 2: Integer key and string key are different
local t2 = {}
t2[1] = "integer"
t2["1"] = "string"
assert(t2[1] == "integer", "t2[1] should be 'integer'")
assert(t2["1"] == "string", "t2['1'] should be 'string'")

-- Test 3: pairs returns correct key types
local count_int = 0
local count_str = 0
for k, v in pairs(t2) do
    if type(k) == "number" then
        count_int = count_int + 1
    elseif type(k) == "string" then
        count_str = count_str + 1
    end
end
assert(count_int == 1, "should have 1 integer key")
assert(count_str == 1, "should have 1 string key")

-- Test 4: table.insert uses integer keys
local t3 = {}
table.insert(t3, "a")
table.insert(t3, "b")
assert(t3[1] == "a", "t3[1] should be 'a'")
assert(t3[2] == "b", "t3[2] should be 'b'")
assert(#t3 == 2, "length should be 2")

-- Test 5: table.remove uses integer keys
local removed = table.remove(t3)
assert(removed == "b", "removed should be 'b'")
assert(#t3 == 1, "length should be 1")

-- Test 6: table.concat uses integer keys
local t4 = {"hello", "world"}
local result = table.concat(t4, " ")
assert(result == "hello world", "concat should work")

-- Test 7: table.pack uses integer keys
local t5 = table.pack(1, 2, 3)
assert(t5[1] == 1, "t5[1] should be 1")
assert(t5[2] == 2, "t5[2] should be 2")
assert(t5[3] == 3, "t5[3] should be 3")
assert(t5.n == 3, "t5.n should be 3")

-- Test 8: table.unpack uses integer keys
local a, b, c = table.unpack(t5, 1, 3)
assert(a == 1, "a should be 1")
assert(b == 2, "b should be 2")
assert(c == 3, "c should be 3")

-- Test 9: table.sort uses integer keys
local t6 = {3, 1, 2}
table.sort(t6)
assert(t6[1] == 1, "t6[1] should be 1 after sort")
assert(t6[2] == 2, "t6[2] should be 2 after sort")
assert(t6[3] == 3, "t6[3] should be 3 after sort")

-- Test 10: table.move uses integer keys
local t7 = {1, 2, 3}
local t8 = {}
table.move(t7, 1, 3, 1, t8)
assert(t8[1] == 1, "t8[1] should be 1")
assert(t8[2] == 2, "t8[2] should be 2")
assert(t8[3] == 3, "t8[3] should be 3")

print("All integer key tests passed!")
