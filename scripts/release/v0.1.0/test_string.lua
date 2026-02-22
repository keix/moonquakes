-- v0.1.0 Release Test: String Library

print("=== string.len ===")
assert(string.len("hello") == 5)
assert(string.len("") == 0)
assert(#"hello" == 5)

print("=== string.sub ===")
assert(string.sub("hello", 2, 4) == "ell")
assert(string.sub("hello", 2) == "ello")
assert(string.sub("hello", -2) == "lo")
assert(string.sub("hello", 1, -2) == "hell")

print("=== string.upper/lower ===")
assert(string.upper("hello") == "HELLO")
assert(string.lower("HELLO") == "hello")

print("=== string.byte/char ===")
assert(string.byte("ABC") == 65)
assert(string.byte("ABC", 2) == 66)
assert(string.char(65, 66, 67) == "ABC")

print("=== string.rep ===")
assert(string.rep("ab", 3) == "ababab")
assert(string.rep("x", 0) == "")
assert(string.rep("ab", 3, "-") == "ab-ab-ab")

print("=== string.reverse ===")
assert(string.reverse("hello") == "olleh")
assert(string.reverse("") == "")

print("=== string.find ===")
local s, e = string.find("hello world", "world")
assert(s == 7 and e == 11)
assert(string.find("hello", "xyz") == nil)

print("=== string.match ===")
assert(string.match("hello123", "%d+") == "123")
assert(string.match("hello", "%d+") == nil)

print("=== string.gsub ===")
assert(string.gsub("hello", "l", "L") == "heLLo")
local result, count = string.gsub("hello", "l", "L")
assert(count == 2)

print("=== string.format ===")
assert(string.format("%d", 42) == "42")
assert(string.format("%s", "hello") == "hello")
assert(string.format("%x", 255) == "ff")
assert(string.format("%.2f", 3.14159) == "3.14")

print("=== string.gmatch ===")
local words = {}
for w in string.gmatch("hello world lua", "%w+") do
    words[#words + 1] = w
end
assert(#words == 3)

print("[PASS] test_string.lua")
