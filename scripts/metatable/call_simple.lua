-- Simple __call test
local mt = {
    __call = function(self, x)
        print("called with:", type(self), type(x), x)
        return 42
    end
}

local obj = {}
setmetatable(obj, mt)

local result = obj(21)
print("result:", result)
