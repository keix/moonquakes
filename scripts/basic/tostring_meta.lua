-- Test __tostring metamethod

-- Basic __tostring
local t = {}
setmetatable(t, {
    __tostring = function(self)
        return "custom table"
    end
})
print(tostring(t))
-- expect: custom table

-- __tostring with data
local obj = { name = "test", value = 42 }
setmetatable(obj, {
    __tostring = function(self)
        return "Object(" .. self.name .. "=" .. self.value .. ")"
    end
})
print(tostring(obj))
-- expect: Object(test=42)

-- __tostring used by print
local p = { x = 10, y = 20 }
setmetatable(p, {
    __tostring = function(self)
        return "Point(" .. self.x .. "," .. self.y .. ")"
    end
})
print(p)
-- expect: Point(10,20)

-- Without __tostring falls back to default
local plain = {}
local s = tostring(plain)
print(s == "<table>")
-- expect: true

print("__tostring tests passed")
-- expect: __tostring tests passed
