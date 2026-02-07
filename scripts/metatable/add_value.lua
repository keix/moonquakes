-- Test __add with table field access
local mt = {
    __add = function(a, b)
        print("a type:", type(a))
        print("b type:", type(b))
        -- Just return a number for now
        return 100
    end
}

local t1 = { value = 10 }
local t2 = { value = 20 }
setmetatable(t1, mt)

local result = t1 + t2
print("result:", result)
