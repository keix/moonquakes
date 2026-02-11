-- Test file:lines method
local f = io.open("/tmp/flines_test.txt", "w")
f:write("alpha\nbeta\ngamma\n")
f:close()

local f2 = io.open("/tmp/flines_test.txt", "r")
local count = 0
for line in f2:lines() do
    count = count + 1
    print(count .. ": " .. line)
end
f2:close()
print("total: " .. count)
-- expect: 1: alpha
-- expect: 2: beta
-- expect: 3: gamma
-- expect: total: 3
