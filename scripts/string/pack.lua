-- Test string.pack

-- Pack bytes
local b = string.pack("bB", -128, 255)
print("bytes len: " .. #b)
-- expect: bytes len: 2

-- Pack shorts (little endian)
local s = string.pack("<hH", -1, 65535)
print("shorts len: " .. #s)
-- expect: shorts len: 4

-- Pack integers
local i = string.pack("<i4I4", -1, 4294967295)
print("ints len: " .. #i)
-- expect: ints len: 8

-- Pack long
local l = string.pack("<j", 9223372036854775807)
print("long len: " .. #l)
-- expect: long len: 8

-- Pack float
local f = string.pack("<f", 3.14)
print("float len: " .. #f)
-- expect: float len: 4

-- Pack double
local d = string.pack("<d", 3.14159265358979)
print("double len: " .. #d)
-- expect: double len: 8

-- Pack fixed string
local c = string.pack("c5", "abc")
print("c5 len: " .. #c)
-- expect: c5 len: 5

-- Pack zero-terminated string
local z = string.pack("z", "hello")
print("z len: " .. #z)
-- expect: z len: 6

-- Pack string with length prefix
local s2 = string.pack("<s2", "test")
print("s2 len: " .. #s2)
-- expect: s2 len: 6

-- Pack multiple values
local multi = string.pack("<BHI4", 10, 1000, 100000)
print("multi len: " .. #multi)
-- expect: multi len: 7

-- Pack with endianness
local be = string.pack(">I4", 0x12345678)
local le = string.pack("<I4", 0x12345678)
print("be byte1: " .. string.byte(be, 1))
print("le byte1: " .. string.byte(le, 1))
-- expect: be byte1: 18
-- expect: le byte1: 120
