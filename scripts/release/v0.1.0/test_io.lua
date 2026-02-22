-- v0.1.0 Release Test: IO Library

print("=== io.write/flush ===")
io.write("test output\n")
io.flush()

print("=== io.open/read/close ===")
local f = io.open("/tmp/moonquakes_test_io.txt", "w")
f:write("hello world\n")
f:write("line 2\n")
f:close()

local f2 = io.open("/tmp/moonquakes_test_io.txt", "r")
local line1 = f2:read("l")
assert(line1 == "hello world")
local line2 = f2:read("l")
assert(line2 == "line 2")
f2:close()

print("=== io.read modes ===")
local f3 = io.open("/tmp/moonquakes_test_io.txt", "r")
local all = f3:read("a")
assert(#all > 0)
f3:close()

print("=== io.lines ===")
local count = 0
for line in io.lines("/tmp/moonquakes_test_io.txt") do
    count = count + 1
end
assert(count == 2)

print("=== io.type ===")
local f4 = io.open("/tmp/moonquakes_test_io.txt", "r")
assert(io.type(f4) == "file")
f4:close()
assert(io.type(f4) == "closed file")
assert(io.type("not a file") == nil)

print("=== io.tmpfile ===")
local tmp = io.tmpfile()
tmp:write("temp data")
tmp:seek("set")
local data = tmp:read("a")
assert(data == "temp data")
tmp:close()

print("=== file:seek ===")
local f5 = io.open("/tmp/moonquakes_test_io.txt", "r")
local pos = f5:seek()
assert(pos == 0)
f5:seek("end")
local endpos = f5:seek()
assert(endpos > 0)
f5:close()

-- Cleanup
os.remove("/tmp/moonquakes_test_io.txt")

print("[PASS] test_io.lua")
