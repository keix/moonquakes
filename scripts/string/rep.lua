-- Test string.rep
assert(string.rep("ab", 3) == "ababab", "rep('ab', 3)")
assert(string.rep("x", 5) == "xxxxx", "rep('x', 5)")
assert(string.rep("a", 1) == "a", "rep single")
assert(string.rep("a", 0) == "", "rep zero")
assert(string.rep("hello", 2) == "hellohello", "rep word")

-- With separator
assert(string.rep("a", 3, "-") == "a-a-a", "rep with separator")
assert(string.rep("ab", 2, ",") == "ab,ab", "rep word with separator")
assert(string.rep("x", 4, "::") == "x::x::x::x", "rep with long separator")

print("rep passed")
