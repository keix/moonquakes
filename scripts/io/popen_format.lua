-- io.popen with string.format command
local name = "world"
local cmd = string.format("echo 'Hello, %s!'", name)
local output = io.popen(cmd):read("*a")
assert(output == "Hello, world!\n", "format command failed: " .. output)
print("popen_format passed")
