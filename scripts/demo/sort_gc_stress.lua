-- table.sort + comparator + GC stress test
-- Tests GC safety when callValue is used for comparator calls

print("=== table.sort + GC Stress Test ===")
print("")

-- Test 1: Basic comparator
print("--- Test 1: Basic comparator ---")
local t1 = {5, 2, 8, 1, 9, 3, 7, 4, 6}
table.sort(t1, function(a, b) return a < b end)
local ok1 = true
for i = 1, 8 do
    if t1[i] > t1[i + 1] then ok1 = false end
end
print("Basic sort: " .. (ok1 and "PASS" or "FAIL"))

-- Test 2: Comparator that creates strings (potential GC trigger)
print("--- Test 2: String-creating comparator ---")
local t2 = {30, 10, 50, 20, 40}
local call_count = 0
table.sort(t2, function(a, b)
    call_count = call_count + 1
    -- Create strings to potentially trigger GC
    local sa = "value_" .. a
    local sb = "value_" .. b
    return a < b
end)
local ok2 = true
for i = 1, 4 do
    if t2[i] > t2[i + 1] then ok2 = false end
end
print("String comparator: " .. (ok2 and "PASS" or "FAIL") .. " (calls: " .. call_count .. ")")

-- Test 3: Large array with GC-heavy comparator
print("--- Test 3: Large array + GC stress ---")
local t3 = {}
for i = 1, 100 do
    t3[i] = 101 - i  -- reverse order
end

local gc_comparisons = 0
table.sort(t3, function(a, b)
    gc_comparisons = gc_comparisons + 1
    -- Create multiple strings and tables to stress GC
    local temp_str = "comparing_" .. a .. "_vs_" .. b
    local temp_tbl = {a = a, b = b, result = a < b}
    return a < b
end)

local ok3 = true
for i = 1, 99 do
    if t3[i] > t3[i + 1] then
        ok3 = false
        print("  Error at index " .. i .. ": " .. t3[i] .. " > " .. t3[i + 1])
    end
end
print("Large array sort: " .. (ok3 and "PASS" or "FAIL") .. " (comparisons: " .. gc_comparisons .. ")")

-- Test 4: Nested table values with string keys
print("--- Test 4: Table of tables ---")
local t4 = {}
for i = 1, 20 do
    t4[i] = {
        id = 21 - i,
        name = "item_" .. (21 - i),
        data = {x = i, y = i * 2}
    }
end

table.sort(t4, function(a, b)
    -- Access nested fields, create strings
    local key_a = a.name .. "_" .. a.id
    local key_b = b.name .. "_" .. b.id
    return a.id < b.id
end)

local ok4 = true
for i = 1, 19 do
    if t4[i].id > t4[i + 1].id then ok4 = false end
end
print("Table sort: " .. (ok4 and "PASS" or "FAIL"))

-- Test 5: Force GC during sort
print("--- Test 5: Explicit GC during sort ---")
local t5 = {}
for i = 1, 50 do
    t5[i] = 51 - i
end

local gc_triggered = 0
table.sort(t5, function(a, b)
    -- Force GC every 10 comparisons
    gc_triggered = gc_triggered + 1
    if gc_triggered % 10 == 0 then
        collectgarbage()
    end
    return a < b
end)

local ok5 = true
for i = 1, 49 do
    if t5[i] > t5[i + 1] then ok5 = false end
end
print("GC-forced sort: " .. (ok5 and "PASS" or "FAIL") .. " (GC calls: " .. (gc_triggered // 10) .. ")")

-- Summary
print("")
print("=== Summary ===")
local all_pass = ok1 and ok2 and ok3 and ok4 and ok5
if all_pass then
    print("All tests PASSED!")
else
    print("Some tests FAILED!")
end
print("")
print("=== table.sort + GC Stress Test Complete ===")
