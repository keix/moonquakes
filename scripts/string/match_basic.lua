-- Basic string.match tests
local m = string.match("hello world", "world")
assert(m == "world", "literal match failed")
print("match_basic passed")
