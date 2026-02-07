-- string.match with capture
local m = string.match("hello world", "(world)")
assert(m == "world", "capture failed")

-- Multiple captures returns only first (VM limitation)
local a = string.match("foo bar", "(%a+) (%a+)")
assert(a == "foo", "first capture failed")

-- Second word capture
local b = string.match("foo bar", "%a+ (%a+)")
assert(b == "bar", "second capture failed")

print("match_capture passed")
