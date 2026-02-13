-- Test __mode metamethod (weak tables)

-- Test 1: weak values - collectible value should be removed
print("Test 1: Weak values with collectible value")
local t1 = setmetatable({}, {__mode = "v"})
do
    local value = {data = "temporary"}
    t1.key = value
    assert(t1.key ~= nil, "Value should exist before GC")
end
-- value is now unreachable
collectgarbage()
collectgarbage()
assert(t1.key == nil, "Weak value should be collected")
print("  Test 1 PASSED")

-- Test 2: weak values - reachable value should stay
print("Test 2: Weak values with reachable value")
local t2 = setmetatable({}, {__mode = "v"})
local alive = {data = "persistent"}
t2.key = alive
collectgarbage()
collectgarbage()
assert(t2.key == alive, "Reachable value should stay")
print("  Test 2 PASSED")

-- Test 3: weak values - non-collectible values stay
print("Test 3: Weak values with non-collectible types")
local t3 = setmetatable({}, {__mode = "v"})
t3.num = 42
t3.str = "hello"
t3.bool = true
collectgarbage()
collectgarbage()
assert(t3.num == 42, "Number should stay")
assert(t3.str == "hello", "String should stay")
assert(t3.bool == true, "Boolean should stay")
print("  Test 3 PASSED")

-- Test 4: strong table - values should NOT be collected
print("Test 4: Strong table keeps values")
local t4 = {}
do
    local value = {data = "kept"}
    t4.key = value
end
collectgarbage()
collectgarbage()
assert(t4.key ~= nil, "Strong table should keep value")
print("  Test 4 PASSED")

-- Test 5: weak both (kv) - value collected when unreachable
print("Test 5: Weak both (kv)")
local t5 = setmetatable({}, {__mode = "kv"})
do
    local value = {data = "temp"}
    t5.key = value
end
collectgarbage()
collectgarbage()
assert(t5.key == nil, "Weak value in kv table should be collected")
print("  Test 5 PASSED")

-- Test 6: multiple weak values
print("Test 6: Multiple weak values")
local t6 = setmetatable({}, {__mode = "v"})
local kept = {data = "kept"}
do
    t6.a = {data = "a"}
    t6.b = {data = "b"}
    t6.c = kept
    t6.d = {data = "d"}
end
collectgarbage()
collectgarbage()
assert(t6.a == nil, "Unreachable value a should be collected")
assert(t6.b == nil, "Unreachable value b should be collected")
assert(t6.c == kept, "Reachable value c should stay")
assert(t6.d == nil, "Unreachable value d should be collected")
print("  Test 6 PASSED")

-- Test 7: case insensitive mode
print("Test 7: Case insensitive mode parsing")
local t7 = setmetatable({}, {__mode = "V"})
do
    t7.key = {data = "temp"}
end
collectgarbage()
collectgarbage()
assert(t7.key == nil, "Uppercase V should work as weak values")
print("  Test 7 PASSED")

print("")
print("=== All weak table tests PASSED ===")
