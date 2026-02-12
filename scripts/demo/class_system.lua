-- Simple OOP-like class system using metatables
print("=== Class System Demo ===")

-- Point class
local Point = {}
Point.__index = Point

Point.__tostring = function(self)
    return "Point(" .. self.x .. ", " .. self.y .. ")"
end

Point.new = function(x, y)
    local self = setmetatable({}, Point)
    self.x = x or 0
    self.y = y or 0
    return self
end

Point.distance = function(self, other)
    local dx = self.x - other.x
    local dy = self.y - other.y
    return math.sqrt(dx * dx + dy * dy)
end

Point.translate = function(self, dx, dy)
    self.x = self.x + dx
    self.y = self.y + dy
    return self
end

-- Rectangle class
local Rectangle = {}
Rectangle.__index = Rectangle

Rectangle.__tostring = function(self)
    return "Rectangle(" .. self.x .. ", " .. self.y .. ", " .. self.width .. ", " .. self.height .. ")"
end

Rectangle.new = function(x, y, width, height)
    local self = setmetatable({}, Rectangle)
    self.x = x or 0
    self.y = y or 0
    self.width = width or 0
    self.height = height or 0
    return self
end

Rectangle.area = function(self)
    return self.width * self.height
end

Rectangle.contains = function(self, point)
    return point.x >= self.x and point.x <= self.x + self.width and
           point.y >= self.y and point.y <= self.y + self.height
end

Rectangle.center = function(self)
    return Point.new(self.x + self.width / 2, self.y + self.height / 2)
end

-- Test Point class
print("\n-- Point Tests --")
local p1 = Point.new(0, 0)
local p2 = Point.new(3, 4)
print("p1 = " .. tostring(p1))
print("p2 = " .. tostring(p2))
print("distance(p1, p2) = " .. p1:distance(p2))
-- expect: distance(p1, p2) = 5

p1:translate(1, 1)
print("p1 after translate(1,1) = " .. tostring(p1))
-- expect: p1 after translate(1,1) = Point(1, 1)

-- Test Rectangle class
print("\n-- Rectangle Tests --")
local rect = Rectangle.new(0, 0, 10, 5)
print("rect = " .. tostring(rect))
print("rect:area() = " .. rect:area())
-- expect: rect:area() = 50

local center = rect:center()
print("rect:center() = " .. tostring(center))
-- expect: rect:center() = Point(5, 2.5)

local inside = Point.new(5, 2)
local outside = Point.new(15, 2)
print("contains(5,2) = " .. tostring(rect:contains(inside)))
-- expect: contains(5,2) = true
print("contains(15,2) = " .. tostring(rect:contains(outside)))
-- expect: contains(15,2) = false

-- Collection of shapes
print("\n-- Shape Collection --")
local shapes = {}
shapes[1] = Point.new(1, 2)
shapes[2] = Point.new(5, 10)
shapes[3] = Rectangle.new(0, 0, 20, 10)

for i = 1, 3 do
    print("shapes[" .. i .. "] = " .. tostring(shapes[i]))
end

print("\n=== Class System Demo PASSED ===")
