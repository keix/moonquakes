-- No-parens function call with string
local function greet(name)
    return "Hello, " .. name
end
return greet "World"
-- expect: Hello, World
