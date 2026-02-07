-- Simple __add test
local mt = {
    __add = function(a, b)
        return 42
    end
}

local t1 = {}
local t2 = {}
setmetatable(t1, mt)

local result = t1 + t2
print(result)
