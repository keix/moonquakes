-- Test table.insert and table.remove

-- Test insert at end
local t = {}
table.insert(t, "a")
table.insert(t, "b")
table.insert(t, "c")
assert(t[1] == "a", "insert at end 1")
assert(t[2] == "b", "insert at end 2")
assert(t[3] == "c", "insert at end 3")

-- Test insert at position
local t2 = {"a", "c"}
table.insert(t2, 2, "b")
assert(t2[1] == "a", "insert at pos 1")
assert(t2[2] == "b", "insert at pos 2")
assert(t2[3] == "c", "insert at pos 3")

-- Test remove from end (default)
local t3 = {"a", "b", "c"}
local removed = table.remove(t3)
assert(removed == "c", "remove returns last element")
assert(t3[1] == "a", "remove end 1")
assert(t3[2] == "b", "remove end 2")
assert(t3[3] == nil, "remove end 3 is nil")

-- Test remove from position
local t4 = {"a", "b", "c", "d"}
local removed2 = table.remove(t4, 2)
assert(removed2 == "b", "remove at pos returns element")
assert(t4[1] == "a", "remove pos 1")
assert(t4[2] == "c", "remove pos 2 shifted")
assert(t4[3] == "d", "remove pos 3 shifted")
assert(t4[4] == nil, "remove pos 4 is nil")

print("insert_remove passed")
