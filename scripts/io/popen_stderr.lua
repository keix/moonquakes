-- io.popen capturing stdout
local cmd = "echo stdout_test"
local p = io.popen(cmd)
local output = p:read("*a")
p:close()

-- Check output matches expected
assert(output == "stdout_test\n", "output should be 'stdout_test'")
print("popen_stderr passed")
