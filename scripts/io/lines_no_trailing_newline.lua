-- Test io.lines with file without trailing newline
local f = io.open("/tmp/no_newline.txt", "w")
f:write("first\nsecond\nthird")  -- no newline at end
f:close()

local lines = {}
for line in io.lines("/tmp/no_newline.txt") do
    lines[#lines + 1] = line
end

print("line count: " .. #lines)
print("last line: >" .. lines[#lines] .. "<")
-- expect: line count: 3
-- expect: last line: >third<
