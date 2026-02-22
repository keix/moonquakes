-- Simple test module
local M = {}

M.name = "mylib"
M.version = "1.0.0"

function M.greet(name)
    return "Hello, " .. (name or "World") .. "!"
end

function M.add(a, b)
    return a + b
end

return M
