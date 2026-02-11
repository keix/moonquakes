-- Test io.read function

-- Create test file
local f = io.open("/tmp/ioread_test.txt", "w")
f:write("first line\n")
f:write("second line\n")
f:write("third line")
f:close()

-- Set as default input
io.input("/tmp/ioread_test.txt")

-- Read line (default format)
print("default: " .. io.read())

-- Read line explicitly
print("*l: " .. io.read("*l"))

-- Read line with newline
local line = io.read("*L")
print("*L: >" .. line .. "<")

-- Reset input and read all
io.input("/tmp/ioread_test.txt")
local all = io.read("*a")
print("*a length: " .. #all)

-- Verify content
io.input("/tmp/ioread_test.txt")
local count = 0
while true do
    local l = io.read()
    if l == nil then break end
    count = count + 1
end
print("line count: " .. count)
-- expect: default: first line
-- expect: *l: second line
-- expect: *L: >third line<
-- expect: *a length: 33
-- expect: line count: 3
