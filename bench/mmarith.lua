-- Metamethod arithmetic: __add/__mul dispatch on 2D vectors, one table
-- allocation per operation (metamethod + constructor mix).
local Vec = {}
Vec.__index = Vec
Vec.__add = function(a, b)
  return setmetatable({ a[1] + b[1], a[2] + b[2] }, Vec)
end
Vec.__mul = function(a, s)
  return setmetatable({ a[1] * s, a[2] * s }, Vec)
end
local function new(x, y)
  return setmetatable({ x, y }, Vec)
end
local acc = new(0.0, 0.0)
local v = new(1.5, -0.5)
for i = 1, 400000 do
  acc = acc + v * 0.5
  if i % 1000 == 0 then
    acc = acc * 0.5
  end
end
print(string.format("%.6f %.6f", acc[1], acc[2]))
