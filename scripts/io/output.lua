-- Test io.output function
-- Get default output (stdout)
local default = io.output()
print("default type: " .. io.type(default))

-- Set output to file
io.output("/tmp/output_test.txt")
local h = io.output()
print("after set type: " .. io.type(h))

-- Write to default output
h:write("line 1\n")
h:write("line 2\n")
h:close()

-- Verify content was written
local f = io.open("/tmp/output_test.txt", "r")
print("written content:")
for line in f:lines() do
    print("  " .. line)
end
f:close()

-- Set output from file handle
local f2 = io.open("/tmp/output_test2.txt", "w")
io.output(f2)
local h2 = io.output()
h2:write("from handle\n")
h2:close()

-- Verify
local f3 = io.open("/tmp/output_test2.txt", "r")
print("handle output: " .. f3:read("*a"))
f3:close()
-- expect: default type: file
-- expect: after set type: file
-- expect: written content:
-- expect:   line 1
-- expect:   line 2
-- expect: handle output: from handle
