-- Test generic for loop

-- Test with pairs
local t = {a = 1, b = 2, c = 3}
local count = 0
local sum = 0

for k, v in pairs(t) do
    count = count + 1
    sum = sum + v
end

assert(count == 3, "pairs should iterate 3 times")
assert(sum == 6, "sum should be 6")

-- Test with ipairs
local arr = {10, 20, 30, 40, 50}
count = 0
sum = 0

for i, v in ipairs(arr) do
    count = count + 1
    sum = sum + v
end

assert(count == 5, "ipairs should iterate 5 times")
assert(sum == 150, "sum should be 150")

-- Test single variable
local keys = {}
local key_count = 0
for k in pairs(t) do
    key_count = key_count + 1
    keys[key_count] = k
end

assert(key_count == 3, "single var pairs should iterate 3 times")

print("All generic for loop tests passed!")
