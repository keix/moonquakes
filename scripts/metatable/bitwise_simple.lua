-- Simple bitwise metamethod tests
local mt = {
    __band = function(a, b)
        return a.value & b.value
    end,
    __bor = function(a, b)
        return a.value | b.value
    end,
    __bxor = function(a, b)
        return a.value ~ b.value
    end,
    __bnot = function(a)
        return ~a.value
    end,
    __shl = function(a, b)
        return a.value << b
    end,
    __shr = function(a, b)
        return a.value >> b
    end
}

local obj1 = { value = 0xFF }
local obj2 = { value = 0x0F }

setmetatable(obj1, mt)
setmetatable(obj2, mt)

-- Test __band
local result = obj1 & obj2
print("band:", result)
assert(result == 0x0F, "band failed")

-- Test __bor
result = obj1 | obj2
print("bor:", result)
assert(result == 0xFF, "bor failed")

-- Test __bxor
result = obj1 ~ obj2
print("bxor:", result)
assert(result == 0xF0, "bxor failed")

-- Test __bnot
result = ~obj1
print("bnot:", result)
assert(result == ~0xFF, "bnot failed")

-- Test __shl
result = obj1 << 4
print("shl:", result)
assert(result == 0xFF0, "shl failed")

-- Test __shr
result = obj1 >> 4
print("shr:", result)
assert(result == 0x0F, "shr failed")

print("bitwise metamethod tests passed")
