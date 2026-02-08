-- Test table.pack and table.unpack

-- Test table.pack
local t = table.pack(1, 2, 3)
assert(t[1] == 1, "pack[1]")
assert(t[2] == 2, "pack[2]")
assert(t[3] == 3, "pack[3]")
assert(t.n == 3, "pack.n")

-- Pack with mixed types
local t2 = table.pack("a", true, nil, 42)
assert(t2[1] == "a", "pack mixed 1")
assert(t2[2] == true, "pack mixed 2")
assert(t2[3] == nil, "pack mixed 3")
assert(t2[4] == 42, "pack mixed 4")
assert(t2.n == 4, "pack mixed n")

-- Empty pack
local t3 = table.pack()
assert(t3.n == 0, "pack empty")

-- Test table.unpack
local a, b, c = table.unpack({10, 20, 30})
assert(a == 10, "unpack a")
assert(b == 20, "unpack b")
assert(c == 30, "unpack c")

-- Unpack with range
local d, e = table.unpack({1, 2, 3, 4, 5}, 2, 3)
assert(d == 2, "unpack range d")
assert(e == 3, "unpack range e")

-- Unpack single element
local x = table.unpack({100}, 1, 1)
assert(x == 100, "unpack single")

print("pack_unpack passed")
