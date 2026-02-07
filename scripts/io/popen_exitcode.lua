-- io.popen exit code test
local p1 = io.popen("exit 0")
p1:read("*a")
local ok1 = p1:close()
assert(ok1 == true, "exit 0 should return true")

local p2 = io.popen("exit 1")
p2:read("*a")
local ok2 = p2:close()
assert(ok2 == nil, "exit 1 should return nil")

local p3 = io.popen("exit 42")
p3:read("*a")
local ok3 = p3:close()
assert(ok3 == nil, "exit 42 should return nil")

print("popen_exitcode passed")
