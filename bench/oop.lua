-- Metatable-based method dispatch: the classic Lua OOP style.
local Point = {}
Point.__index = Point

function Point.new(x, y)
  return setmetatable({ x = x, y = y }, Point)
end

function Point:dot(o)
  return self.x * o.x + self.y * o.y
end

function Point:add(o)
  self.x = self.x + o.x
  self.y = self.y + o.y
  return self
end

function Point:norm2()
  return self:dot(self)
end

local a = Point.new(1, 2)
local b = Point.new(3, 4)
local acc = 0
for i = 1, 5000000 do
  acc = acc + a:dot(b)
  a:add(b)
  acc = acc + a:norm2() % 1000
  a.x = i % 100
  a.y = (i + 1) % 100
end
print(acc)
