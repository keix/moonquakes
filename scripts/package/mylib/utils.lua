-- Nested module: mylib.utils
local M = {}

M.name = "mylib.utils"

function M.double(x)
    return x * 2
end

function M.triple(x)
    return x * 3
end

return M
