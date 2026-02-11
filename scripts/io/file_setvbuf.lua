-- Test file:setvbuf method
local f = io.open("/tmp/setvbuf_test.txt", "w")

-- Test all valid modes
print("no: " .. tostring(f:setvbuf("no")))
print("full: " .. tostring(f:setvbuf("full")))
print("line: " .. tostring(f:setvbuf("line")))

-- Test with size argument (optional)
print("full with size: " .. tostring(f:setvbuf("full", 4096)))

-- Write and close
f:write("buffered content")
f:close()

-- Verify content was written
local f2 = io.open("/tmp/setvbuf_test.txt", "r")
print("content: " .. f2:read("*a"))
f2:close()
-- expect: no: true
-- expect: full: true
-- expect: line: true
-- expect: full with size: true
-- expect: content: buffered content
