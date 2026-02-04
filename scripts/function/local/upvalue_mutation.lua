-- Upvalue mutation test
local count = 0
local function inc()
    count = count + 1
end
inc()
inc()
inc()
return count
-- expect: 3
