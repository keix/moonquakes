-- Test io.lines with empty file
local f = io.open("/tmp/empty_lines.txt", "w")
f:close()

local count = 0
for line in io.lines("/tmp/empty_lines.txt") do
    count = count + 1
    print("unexpected line: " .. line)
end
print("lines in empty file: " .. count)
-- expect: lines in empty file: 0
