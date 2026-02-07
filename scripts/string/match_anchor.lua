-- string.match with anchors
-- ^ - start anchor
local m1 = string.match("hello", "^he")
assert(m1 == "he", "^ anchor failed")

local m2 = string.match("hello", "^lo")
assert(m2 == nil, "^ should not match in middle")

-- $ - end anchor
local m3 = string.match("hello", "lo$")
assert(m3 == "lo", "$ anchor failed")

local m4 = string.match("hello", "he$")
assert(m4 == nil, "$ should not match at start")

print("match_anchor passed")
