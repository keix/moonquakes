-- UTF-8 library basic tests

-- Test utf8.char
print("Testing utf8.char...")
local s1 = utf8.char(65)  -- 'A'
assert(s1 == "A", "utf8.char(65) should be 'A'")

local s2 = utf8.char(72, 101, 108, 108, 111)  -- 'Hello'
assert(s2 == "Hello", "utf8.char should create 'Hello'")

-- Japanese hiragana 'あ' = U+3042
local s3 = utf8.char(0x3042)
assert(s3 == "あ", "utf8.char(0x3042) should be 'あ'")

-- Multiple Japanese characters
local s4 = utf8.char(0x3042, 0x3044, 0x3046)  -- あいう
assert(s4 == "あいう", "utf8.char should create 'あいう'")

print("utf8.char tests passed!")

-- Test utf8.len
print("Testing utf8.len...")
assert(utf8.len("Hello") == 5, "utf8.len('Hello') should be 5")
assert(utf8.len("") == 0, "utf8.len('') should be 0")
assert(utf8.len("あいう") == 3, "utf8.len('あいう') should be 3")
assert(utf8.len("Hello世界") == 7, "utf8.len('Hello世界') should be 7")

-- Test with range
assert(utf8.len("Hello", 1, 3) == 3, "utf8.len with range")

print("utf8.len tests passed!")

-- Test utf8.codepoint
print("Testing utf8.codepoint...")
assert(utf8.codepoint("A") == 65, "utf8.codepoint('A') should be 65")
assert(utf8.codepoint("あ") == 0x3042, "utf8.codepoint('あ') should be 0x3042")

-- Multiple codepoints
local c1, c2, c3 = utf8.codepoint("ABC", 1, 3)
assert(c1 == 65 and c2 == 66 and c3 == 67, "utf8.codepoint with range")

print("utf8.codepoint tests passed!")

-- Test utf8.offset
print("Testing utf8.offset...")
local str = "あいう"
-- Each Japanese char is 3 bytes, so positions are: 1, 4, 7
assert(utf8.offset(str, 1) == 1, "utf8.offset first char")
assert(utf8.offset(str, 2) == 4, "utf8.offset second char")
assert(utf8.offset(str, 3) == 7, "utf8.offset third char")

-- n=0 should find start of character
assert(utf8.offset(str, 0, 2) == 1, "utf8.offset n=0 finds char start")
assert(utf8.offset(str, 0, 4) == 4, "utf8.offset n=0 at char start")

print("utf8.offset tests passed!")

-- Test utf8.codes
print("Testing utf8.codes...")
local chars = {}
for pos, code in utf8.codes("Aあ") do
    table.insert(chars, {pos = pos, code = code})
end
assert(#chars == 2, "utf8.codes should iterate 2 chars")
assert(chars[1].pos == 1 and chars[1].code == 65, "first char is 'A' at pos 1")
assert(chars[2].pos == 2 and chars[2].code == 0x3042, "second char is 'あ' at pos 2")

print("utf8.codes tests passed!")

print("All UTF-8 tests passed!")
