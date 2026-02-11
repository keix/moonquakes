-- Test string.unpack

-- Unpack bytes
local data = string.pack("bB", -128, 255)
local b1, b2, pos = string.unpack("bB", data)
print("bytes: " .. b1 .. ", " .. b2)
print("pos after bytes: " .. pos)
-- expect: bytes: -128, 255
-- expect: pos after bytes: 3

-- Unpack shorts (little endian)
data = string.pack("<hH", -1, 65535)
local h1, h2, pos2 = string.unpack("<hH", data)
print("shorts: " .. h1 .. ", " .. h2)
-- expect: shorts: -1, 65535

-- Unpack integers
data = string.pack("<i4I4", -1, 4294967295)
local i1, i2, pos3 = string.unpack("<i4I4", data)
print("ints: " .. i1 .. ", " .. i2)
-- expect: ints: -1, 4294967295

-- Unpack long
data = string.pack("<j", 1234567890123)
local l1, pos4 = string.unpack("<j", data)
print("long: " .. l1)
-- expect: long: 1234567890123

-- Unpack float
data = string.pack("<f", 3.14)
local f1, pos5 = string.unpack("<f", data)
print("float approx: " .. (f1 > 3.13 and f1 < 3.15 and "ok" or "fail"))
-- expect: float approx: ok

-- Unpack double
data = string.pack("<d", 3.14159265358979)
local d1, pos6 = string.unpack("<d", data)
print("double approx: " .. (d1 > 3.14 and d1 < 3.15 and "ok" or "fail"))
-- expect: double approx: ok

-- Unpack fixed string
data = string.pack("c5", "hello")
local c1, pos7 = string.unpack("c5", data)
print("c5: " .. c1)
-- expect: c5: hello

-- Unpack zero-terminated string
data = string.pack("z", "world")
local z1, pos8 = string.unpack("z", data)
print("z: " .. z1)
-- expect: z: world

-- Unpack string with length prefix
data = string.pack("<s2", "test")
local s1, pos9 = string.unpack("<s2", data)
print("s2: " .. s1)
-- expect: s2: test

-- Unpack with starting position
data = string.pack("<BHI4", 10, 1000, 100000)
local v1, pos10 = string.unpack("<B", data)
local v2, pos11 = string.unpack("<H", data, pos10)
local v3, pos12 = string.unpack("<I4", data, pos11)
print("multi: " .. v1 .. ", " .. v2 .. ", " .. v3)
-- expect: multi: 10, 1000, 100000

-- Unpack big endian
data = string.pack(">I4", 0x12345678)
local be1, pos13 = string.unpack(">I4", data)
print("big endian: " .. string.format("%x", be1))
-- expect: big endian: 12345678
