-- os file operations test

-- Test os.tmpname
local tmpname = os.tmpname()
assert(tmpname ~= nil, "os.tmpname should return a string")
assert(type(tmpname) == "string", "os.tmpname should return a string")
print("os.tmpname() = " .. tmpname)

-- Test os.rename with non-existent file (should fail)
local ok, err = os.rename("nonexistent_file_12345", "another_name")
assert(ok == nil, "rename of non-existent file should return nil")
assert(err ~= nil, "rename should return error message")
print("os.rename non-existent: nil, " .. err)

-- Test os.remove with non-existent file (should fail)
local ok2, err2 = os.remove("nonexistent_file_12345")
assert(ok2 == nil, "remove of non-existent file should return nil")
assert(err2 ~= nil, "remove should return error message")
print("os.remove non-existent: nil, " .. err2)

-- Test creating, renaming, and removing a file
-- First create a temp file using io
local tmpfile = os.tmpname()
local f = io.open(tmpfile, "w")
if f then
    f:write("test content")
    f:close()
    print("Created temp file: " .. tmpfile)

    -- Test rename
    local newname = tmpfile .. "_renamed"
    local ok3 = os.rename(tmpfile, newname)
    assert(ok3 == true, "rename should succeed")
    print("Renamed to: " .. newname)

    -- Test remove
    local ok4 = os.remove(newname)
    assert(ok4 == true, "remove should succeed")
    print("Removed: " .. newname)
else
    print("Skipping file tests (could not create temp file)")
end

print("All os file operation tests passed!")
