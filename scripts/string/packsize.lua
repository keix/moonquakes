-- Test string.packsize

-- Single byte
print("b: " .. string.packsize("b"))
print("B: " .. string.packsize("B"))
-- expect: b: 1
-- expect: B: 1

-- Shorts
print("h: " .. string.packsize("h"))
print("H: " .. string.packsize("H"))
-- expect: h: 2
-- expect: H: 2

-- Integers with default size
print("i: " .. string.packsize("i"))
print("I: " .. string.packsize("I"))
-- expect: i: 4
-- expect: I: 4

-- Integers with explicit size
print("i2: " .. string.packsize("i2"))
print("I4: " .. string.packsize("I4"))
-- expect: i2: 2
-- expect: I4: 4

-- Long
print("l: " .. string.packsize("l"))
print("L: " .. string.packsize("L"))
-- expect: l: 8
-- expect: L: 8

-- lua_Integer
print("j: " .. string.packsize("j"))
print("J: " .. string.packsize("J"))
-- expect: j: 8
-- expect: J: 8

-- size_t
print("T: " .. string.packsize("T"))
-- expect: T: 8

-- Float and double
print("f: " .. string.packsize("f"))
print("d: " .. string.packsize("d"))
print("n: " .. string.packsize("n"))
-- expect: f: 4
-- expect: d: 8
-- expect: n: 8

-- Fixed string
print("c10: " .. string.packsize("c10"))
-- expect: c10: 10

-- Padding
print("x: " .. string.packsize("x"))
-- expect: x: 1

-- Multiple values
print("bHI4: " .. string.packsize("bHI4"))
-- expect: bHI4: 7

-- Variable-size format (should return nil)
local s_size = string.packsize("s")
local z_size = string.packsize("z")
print("s: " .. tostring(s_size))
print("z: " .. tostring(z_size))
-- expect: s: nil
-- expect: z: nil
