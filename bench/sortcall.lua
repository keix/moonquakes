-- table.sort with a Lua comparator: native-to-Lua callback round trips
-- dominate; also covers integer LCG arithmetic.
local t = {}
local x = 123456789
for i = 1, 200000 do
  x = (1103515245 * x + 12345) % 2147483648
  t[i] = x
end
table.sort(t, function(a, b)
  local ra, rb = a % 1000, b % 1000
  if ra ~= rb then return ra < rb end
  return a < b
end)
local sum = 0
for i = 1, #t, 997 do
  sum = sum + t[i]
end
print(sum)
