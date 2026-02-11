-- Empty return test
-- Note: Moonquakes returns nil for empty chunks (count=1)
-- Lua 5.4 returns 0 values (count=0)

local empty_fn = load("")
local count = select("#", empty_fn())
print("empty return count: " .. count)
-- expect: empty return count: 1
