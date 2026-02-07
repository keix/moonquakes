-- io.popen with empty output
local p = io.popen("true")  -- 'true' command produces no output
local output = p:read("*a")
local ok = p:close()

assert(output == "", "output should be empty")
assert(ok == true, "exit code should be 0")
print("popen_empty passed")
