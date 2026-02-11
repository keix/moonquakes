-- Test io.input function
-- Create test file
local f = io.open("/tmp/input_test.txt", "w")
f:write("test input content\nsecond line\n")
f:close()

-- Get default input (stdin)
local default = io.input()
print("default type: " .. io.type(default))

-- Set input from filename
io.input("/tmp/input_test.txt")
local h = io.input()
print("after set type: " .. io.type(h))

-- Read content
print("line 1: " .. h:read("*l"))
print("line 2: " .. h:read("*l"))

-- Set input from file handle
local f2 = io.open("/tmp/input_test.txt", "r")
io.input(f2)
local h2 = io.input()
print("handle input: " .. h2:read("*l"))
f2:close()
-- expect: default type: file
-- expect: after set type: file
-- expect: line 1: test input content
-- expect: line 2: second line
-- expect: handle input: test input content
