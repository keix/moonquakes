-- io.popen with multiline output
local p = io.popen("echo 'line1'; echo 'line2'; echo 'line3'")

-- Read all at once
local all = p:read("*a")
assert(all == "line1\nline2\nline3\n", "multiline read all failed")
p:close()

print("popen_multiline passed")
