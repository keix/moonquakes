-- Test vararg (...) functionality

-- Test 1: return ...
local function identity(...)
    return ...
end

local a, b, c = identity(1, 2, 3)
assert(a == 1 and b == 2 and c == 3, "return ...")

-- Test 2: f(...)
local function passthrough(...)
    return select("#", ...)
end

assert(passthrough(1, 2, 3, 4) == 4, "f(...) count")

-- Test 3: {...}
local function pack(...)
    return {...}
end

local t = pack(10, 20, 30)
assert(t[1] == 10 and t[2] == 20 and t[3] == 30, "{...}")
assert(#t == 3, "{...} length")

-- Test 4: mixed {prefix, ...}
local function packWithPrefix(prefix, ...)
    return {prefix, ...}
end

local t2 = packWithPrefix("hello", 1, 2, 3)
assert(t2[1] == "hello", "{prefix, ...}[1]")
assert(t2[2] == 1, "{prefix, ...}[2]")
assert(t2[3] == 2, "{prefix, ...}[3]")
assert(t2[4] == 3, "{prefix, ...}[4]")
assert(#t2 == 4, "{prefix, ...} length")

-- Test 5: select with vararg
local function getSecond(...)
    return select(2, ...)
end

assert(getSecond("a", "b", "c") == "b", "select(2, ...)")

-- Test 6: nested vararg
local function outer(...)
    local function inner(...)
        return {...}
    end
    return inner(...)
end

local t3 = outer(100, 200)
assert(t3[1] == 100 and t3[2] == 200, "nested vararg")

print("vararg passed")
