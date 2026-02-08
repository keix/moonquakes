-- Test string.upper and string.lower
assert(string.upper("hello") == "HELLO", "upper('hello')")
assert(string.upper("Hello World") == "HELLO WORLD", "upper mixed case")
assert(string.upper("ABC123") == "ABC123", "upper with numbers")
assert(string.upper("") == "", "upper empty")

assert(string.lower("HELLO") == "hello", "lower('HELLO')")
assert(string.lower("Hello World") == "hello world", "lower mixed case")
assert(string.lower("abc123") == "abc123", "lower with numbers")
assert(string.lower("") == "", "lower empty")

print("case passed")
