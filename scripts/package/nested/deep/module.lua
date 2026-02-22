-- Deeply nested module: nested.deep.module
local M = {}

M.name = "nested.deep.module"
M.depth = 3

function M.path()
    return "nested/deep/module.lua"
end

return M
