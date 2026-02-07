-- string.match with escaped characters
-- %% - literal %
local m1 = string.match("100%", "(%d+%%)")
assert(m1 == "100%", "%% escape failed")

-- %. - literal .
local m2 = string.match("file.txt", "file%.txt")
assert(m2 == "file.txt", "%. escape failed")

print("match_escape passed")
