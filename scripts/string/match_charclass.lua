-- string.match with character classes
-- [^x] - match anything except x
local m1 = string.match("abc\ndef", "([^\n]*)")
assert(m1 == "abc", "negated class failed")

-- [a-z] - range
local m2 = string.match("Hello123", "([a-z]+)")
assert(m2 == "ello", "range class failed")

print("match_charclass passed")
