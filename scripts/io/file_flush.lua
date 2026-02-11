-- Test file:flush method
local f = io.open("/tmp/flush_test.txt", "w")
f:write("before flush")
local ok = f:flush()
print("flush returned: " .. tostring(ok))

-- Verify content was written
local f2 = io.open("/tmp/flush_test.txt", "r")
local content = f2:read("*a")
f2:close()
print("after flush: " .. content)

-- Continue writing and close
f:write(" after flush")
f:close()

-- Verify final content
local f3 = io.open("/tmp/flush_test.txt", "r")
local final = f3:read("*a")
f3:close()
print("final: " .. final)
-- expect: flush returned: true
-- expect: after flush: before flush
-- expect: final: before flush after flush
