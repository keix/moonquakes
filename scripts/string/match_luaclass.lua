-- string.match with Lua character classes
-- %d - digits
local m1 = string.match("abc123def", "(%d+)")
assert(m1 == "123", "%d failed")

-- %a - letters
local m2 = string.match("123abc456", "(%a+)")
assert(m2 == "abc", "%a failed")

-- %s - whitespace
local m3 = string.match("hello world", "(%s+)")
assert(m3 == " ", "%s failed")

-- %w - alphanumeric
local m4 = string.match("!@#abc123!@#", "(%w+)")
assert(m4 == "abc123", "%w failed")

print("match_luaclass passed")
