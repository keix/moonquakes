-- Test io.lines basic functionality
-- Create test file
local f = io.open("/tmp/lines_test.txt", "w")
f:write("line1\nline2\nline3\n")
f:close()

-- Read using io.lines
local count = 0
for line in io.lines("/tmp/lines_test.txt") do
    count = count + 1
    print("line " .. count .. ": " .. line)
end
print("total lines: " .. count)
-- expect: line 1: line1
-- expect: line 2: line2
-- expect: line 3: line3
-- expect: total lines: 3
