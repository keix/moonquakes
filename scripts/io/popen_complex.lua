-- Complex io.popen test with variables
local files = {"a.txt", "b.txt", "c.txt"}
local count = 0

for i = 1, 3 do
    local f = files[i]
    local cmd = string.format("echo 'file: %s'", f)
    local output = io.popen(cmd):read("*a")
    count = count + 1
end

assert(count == 3, "should process 3 files")
print("popen_complex passed")
