-- Test string.byte
assert(string.byte("ABC") == 65, "byte('ABC') should be 65 (A)")
assert(string.byte("ABC", 2) == 66, "byte('ABC', 2) should be 66 (B)")
assert(string.byte("ABC", 3) == 67, "byte('ABC', 3) should be 67 (C)")
assert(string.byte("ABC", -1) == 67, "byte('ABC', -1) should be 67 (C)")
assert(string.byte("ABC", -2) == 66, "byte('ABC', -2) should be 66 (B)")

-- Test string.char
assert(string.char(65) == "A", "char(65) should be 'A'")
assert(string.char(65, 66, 67) == "ABC", "char(65,66,67) should be 'ABC'")
assert(string.char() == "", "char() should be ''")
assert(string.char(72, 101, 108, 108, 111) == "Hello", "char spell 'Hello'")

-- Round trip (single char)
assert(string.char(string.byte("A")) == "A", "round trip single")

print("byte_char passed")
