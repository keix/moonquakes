-- string.match with quantifiers
-- * - zero or more
local m1 = string.match("aaabbb", "(a*)")
assert(m1 == "aaa", "* failed")

-- + - one or more
local m2 = string.match("aaabbb", "(a+)")
assert(m2 == "aaa", "+ failed")

-- ? - zero or one
local m3 = string.match("color", "colou?r")
assert(m3 == "color", "? failed")

local m4 = string.match("colour", "colou?r")
assert(m4 == "colour", "? with char failed")

print("match_quantifiers passed")
