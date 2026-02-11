-- Test io.tmpfile function
local f = io.tmpfile()

-- Verify it's a valid file handle
print("type: " .. io.type(f))

-- Write to temp file
f:write("hello from tmpfile")

-- Seek back to beginning and read
f:seek("set", 0)
local content = f:read("*a")
print("content: " .. content)

-- Write more (appends in our implementation)
f:write(" - appended")
f:seek("set", 0)
print("after append: " .. f:read("*a"))

-- Close (file should be automatically deleted)
f:close()

-- Verify it's closed
print("after close: " .. io.type(f))
-- expect: type: file
-- expect: content: hello from tmpfile
-- expect: after append: hello from tmpfile - appended
-- expect: after close: closed file
