-- Test string.reverse
assert(string.reverse("hello") == "olleh", "reverse('hello')")
assert(string.reverse("a") == "a", "reverse single char")
assert(string.reverse("") == "", "reverse empty")
assert(string.reverse("ab") == "ba", "reverse two chars")
assert(string.reverse("12345") == "54321", "reverse numbers")

-- Double reverse should return original
local s = "testing"
assert(string.reverse(string.reverse(s)) == s, "double reverse")

print("reverse passed")
