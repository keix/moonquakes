-- Chained io.popen call test
local output = io.popen("echo hello"):read("*a")
assert(output == "hello\n", "chained popen failed")
print("popen_chain passed")
