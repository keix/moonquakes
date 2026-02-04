-- Local function call as statement (with return value ignored)
local result = 0
local function compute()
    return 42
end
compute()  -- call as statement, ignore return
return result + compute()  -- call as expression
-- expect: 42
