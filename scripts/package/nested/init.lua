-- Directory module with init.lua
local M = {}

M.name = "nested"
M.loaded_via = "init.lua"

function M.info()
    return "This module was loaded via init.lua"
end

return M
