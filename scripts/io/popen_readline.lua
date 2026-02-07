-- io.popen with line-by-line reading
local p = io.popen("echo 'first'; echo 'second'; echo 'third'")

local line1 = p:read("*l")
local line2 = p:read("*l")
local line3 = p:read("*l")
local line4 = p:read("*l")  -- should be nil

assert(line1 == "first", "line1 failed: " .. tostring(line1))
assert(line2 == "second", "line2 failed: " .. tostring(line2))
assert(line3 == "third", "line3 failed: " .. tostring(line3))
assert(line4 == nil, "line4 should be nil")

p:close()
print("popen_readline passed")
