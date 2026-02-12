-- Test function calls on bracket-accessed values: t["a"]()
local t = {}

-- Basic bracket call
t["fn"] = function() return 1 end
assert(t["fn"]() == 1, "t['fn']() should return 1")

-- With arguments
t["add"] = function(a, b) return a + b end
assert(t["add"](3, 4) == 7, "t['add'](3, 4) should return 7")

-- Variable key
local key = "greet"
t[key] = function(name) return "Hello, " .. name end
assert(t[key]("World") == "Hello, World", "t[key]('World') should greet")

-- Numeric key
t[1] = function() return "one" end
assert(t[1]() == "one", "t[1]() should return 'one'")

-- Method call on bracket access: t[key]:method()
t["obj"] = {
    value = 10,
    double = function(self) return self.value * 2 end
}
assert(t["obj"]:double() == 20, "t['obj']:double() should return 20")

-- Nested bracket then call
t["outer"] = {}
t["outer"]["inner"] = function() return "nested" end
assert(t["outer"]["inner"]() == "nested", "nested bracket call")

-- Mixed dot and bracket
t["x"] = { y = function() return "mixed" end }
assert(t["x"].y() == "mixed", "t['x'].y() should work")

print("bracket_call: PASSED")
