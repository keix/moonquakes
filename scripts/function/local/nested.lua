-- Nested local functions
local function outer(x)
    local function inner(y)
        return y + 1
    end
    return inner(x) * 2
end
return outer(10)
-- expect: 22
