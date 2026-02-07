-- Simple __newindex function test
local mt = {
    __newindex = function(t, k, v)
        print("setting", k, v)
    end
}

local obj = {}
setmetatable(obj, mt)

obj.foo = "bar"
print("done")
