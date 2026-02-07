-- Basic io.popen test
local p = io.popen("echo hello")
local output = p:read("*a")
assert(output == "hello\n", "basic popen failed: got '" .. output .. "'")
p:close()
print("popen_basic passed")
