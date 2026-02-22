-- v0.1.0 Release Test: UTF-8 Library

print("=== utf8.len ===")
assert(utf8.len("hello") == 5)
assert(utf8.len("日本語") == 3)

print("=== utf8.char ===")
assert(utf8.char(65) == "A")
assert(utf8.char(0x3042) == "あ")

print("=== utf8.codepoint ===")
assert(utf8.codepoint("A") == 65)
assert(utf8.codepoint("あ") == 0x3042)

print("=== utf8.codes ===")
local codepoints = {}
for p, c in utf8.codes("ABC") do
    codepoints[#codepoints + 1] = c
end
assert(codepoints[1] == 65 and codepoints[2] == 66 and codepoints[3] == 67)

print("=== utf8.offset ===")
local s = "日本語"
assert(utf8.offset(s, 1) == 1)
assert(utf8.offset(s, 2) == 4)
assert(utf8.offset(s, 3) == 7)

print("=== utf8.charpattern ===")
assert(type(utf8.charpattern) == "string")

print("[PASS] test_utf8.lua")
