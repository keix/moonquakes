-- Test nested index assignment: t[1][1] = x
local t = {}

-- Basic nested assignment
t[1] = {}
t[1][1] = 42
assert(t[1][1] == 42, "t[1][1] should be 42")

-- Three levels deep
t[2] = {}
t[2][3] = {}
t[2][3][4] = "deep"
assert(t[2][3][4] == "deep", "t[2][3][4] should be 'deep'")

-- Mixed string and number keys
t["a"] = {}
t["a"][1] = "mixed"
assert(t["a"][1] == "mixed", "t['a'][1] should be 'mixed'")

t[1]["b"] = {}
t[1]["b"][2] = 99
assert(t[1]["b"][2] == 99, "t[1]['b'][2] should be 99")

-- Variable keys
local i = 1
local j = 2
t[i] = {}
t[i][j] = "var keys"
assert(t[i][j] == "var keys", "t[i][j] should be 'var keys'")

-- Overwrite existing
t[1][1] = 100
assert(t[1][1] == 100, "t[1][1] should be overwritten to 100")

print("nested_index_assign: PASSED")
