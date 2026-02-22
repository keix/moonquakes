-- v0.1.0 Release Test: Metamethods

local mt = {}
local a = setmetatable({val = 10}, mt)
local b = setmetatable({val = 20}, mt)

print("=== __add ===")
mt.__add = function(x, y) return x.val + y.val end
assert((a + b) == 30)

print("=== __sub ===")
mt.__sub = function(x, y) return x.val - y.val end
assert((a - b) == -10)

print("=== __mul ===")
mt.__mul = function(x, y) return x.val * y.val end
assert((a * b) == 200)

print("=== __div ===")
mt.__div = function(x, y) return x.val / y.val end
assert((a / b) == 0.5)

print("=== __mod ===")
mt.__mod = function(x, y) return x.val % y.val end
assert((a % b) == 10)

print("=== __pow ===")
mt.__pow = function(x, y) return x.val ^ y.val end
assert((a ^ b) > 0)

print("=== __unm ===")
mt.__unm = function(x) return -x.val end
assert((-a) == -10)

print("=== __eq ===")
mt.__eq = function(x, y) return x.val == y.val end
local c = setmetatable({val = 10}, mt)
assert((a == c) == true)
assert((a == b) == false)

print("=== __lt ===")
mt.__lt = function(x, y) return x.val < y.val end
assert((a < b) == true)

print("=== __le ===")
mt.__le = function(x, y) return x.val <= y.val end
assert((a <= b) == true)

print("=== __concat ===")
mt.__concat = function(x, y) return tostring(x.val) .. tostring(y.val) end
assert((a .. b) == "1020")

print("=== __len ===")
mt.__len = function(x) return x.val * 2 end
assert((#a) == 20)

print("=== __index (function) ===")
local t1 = setmetatable({}, {__index = function(t, k) return "default_" .. k end})
assert(t1.foo == "default_foo")

print("=== __index (table) ===")
local proto = {x = 100}
local t2 = setmetatable({}, {__index = proto})
assert(t2.x == 100)

print("=== __newindex ===")
local storage = {}
local t3 = setmetatable({}, {
    __newindex = function(t, k, v) storage[k] = v end
})
t3.foo = "bar"
assert(storage.foo == "bar")

print("=== __call ===")
local callable = setmetatable({}, {
    __call = function(t, x) return x * 2 end
})
assert(callable(21) == 42)

print("=== __tostring ===")
local t4 = setmetatable({name = "test"}, {
    __tostring = function(t) return "Object: " .. t.name end
})
assert(tostring(t4) == "Object: test")

print("=== __pairs ===")
local custom_pairs = setmetatable({a=1, b=2}, {
    __pairs = function(t)
        return function(t, k)
            local nk, nv = next(t, k)
            if nk then return nk, nv * 10 end
        end, t, nil
    end
})
local sum = 0
for k, v in pairs(custom_pairs) do sum = sum + v end
assert(sum == 30)

print("[PASS] test_metamethods.lua")
