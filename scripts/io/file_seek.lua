-- Test file:seek method
local f = io.open("/tmp/seek_test.txt", "w")
f:write("hello world")
f:close()

local f2 = io.open("/tmp/seek_test.txt", "r")

-- Test seek("cur") returns current position
local pos = f2:seek()
print("initial: " .. pos)

-- Read and check position advances
f2:read("*l")
print("after read: " .. f2:seek())

-- Test seek("set", 0) goes to beginning
f2:seek("set", 0)
print("after set 0: " .. f2:seek())

-- Test seek("set", 6) goes to position 6
f2:seek("set", 6)
print("after set 6: " .. f2:seek())
print("from pos 6: " .. f2:read("*a"))

-- Test seek("end", 0) goes to end
f2:seek("end", 0)
print("at end: " .. f2:seek())

-- Test seek("end", -5) goes 5 bytes before end
f2:seek("end", -5)
print("end -5: " .. f2:seek())
print("last 5: " .. f2:read("*a"))

f2:close()
-- expect: initial: 0
-- expect: after read: 11
-- expect: after set 0: 0
-- expect: after set 6: 6
-- expect: from pos 6: world
-- expect: at end: 11
-- expect: end -5: 6
-- expect: last 5: world
