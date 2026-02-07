-- string.match with . (any character)
local m1 = string.match("abc", "a.c")
assert(m1 == "abc", ". failed")

local m2 = string.match("aXc", "a.c")
assert(m2 == "aXc", ". with different char failed")

-- .* - any characters
local m3 = string.match("hello world", "(.*)")
assert(m3 == "hello world", ".* failed")

print("match_dot passed")
