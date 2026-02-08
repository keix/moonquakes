-- Test string.len
assert(string.len("hello") == 5, "len('hello') should be 5")
assert(string.len("") == 0, "len('') should be 0")
assert(string.len("abc") == 3, "len('abc') should be 3")
assert(string.len("hello world") == 11, "len with space")
print("len passed")
