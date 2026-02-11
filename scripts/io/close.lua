-- Test io.close function

-- Test with file argument
local f = io.open("/tmp/ioclose_test.txt", "w")
f:write("test content\n")
local ok = io.close(f)
print("close result: " .. tostring(ok))
print("file type after: " .. io.type(f))

-- Verify content was written
local f2 = io.open("/tmp/ioclose_test.txt", "r")
print("content: " .. f2:read("*l"))
f2:close()

-- Test without argument (closes default output)
io.output("/tmp/ioclose_default.txt")
local h = io.output()
h:write("from default output")
io.close()  -- closes default output
print("default type after: " .. io.type(h))

-- Verify
local f3 = io.open("/tmp/ioclose_default.txt", "r")
print("default content: " .. f3:read("*a"))
f3:close()
-- expect: close result: true
-- expect: file type after: closed file
-- expect: content: test content
-- expect: default type after: closed file
-- expect: default content: from default output
