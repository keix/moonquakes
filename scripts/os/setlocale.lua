-- Test os.setlocale

-- Query current locale (should return "C")
print("query all: " .. os.setlocale())

-- Query specific categories
print("query collate: " .. os.setlocale(nil, "collate"))
print("query ctype: " .. os.setlocale(nil, "ctype"))
print("query numeric: " .. os.setlocale(nil, "numeric"))
print("query time: " .. os.setlocale(nil, "time"))

-- Set to C locale explicitly
print("set C: " .. os.setlocale("C"))

-- Set to POSIX locale (equivalent to C)
print("set POSIX: " .. os.setlocale("POSIX"))

-- Set to native locale (empty string)
print("set native: " .. os.setlocale(""))

-- Try invalid category
local result = os.setlocale(nil, "invalid")
print("invalid category: " .. tostring(result))

-- Try unsupported locale
result = os.setlocale("ja_JP.UTF-8")
print("unsupported locale: " .. tostring(result))

-- expect: query all: C
-- expect: query collate: C
-- expect: query ctype: C
-- expect: query numeric: C
-- expect: query time: C
-- expect: set C: C
-- expect: set POSIX: C
-- expect: set native: C
-- expect: invalid category: nil
-- expect: unsupported locale: nil
