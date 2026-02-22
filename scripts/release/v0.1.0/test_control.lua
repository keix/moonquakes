-- v0.1.0 Release Test: Control Flow

print("=== if/elseif/else ===")
local function test_if(x)
    if x < 0 then return "negative"
    elseif x == 0 then return "zero"
    else return "positive"
    end
end
assert(test_if(-1) == "negative")
assert(test_if(0) == "zero")
assert(test_if(1) == "positive")

print("=== while ===")
local i = 0
while i < 5 do i = i + 1 end
assert(i == 5)

print("=== repeat-until ===")
local j = 0
repeat j = j + 1 until j >= 5
assert(j == 5)

print("=== numeric for ===")
local sum = 0
for k = 1, 10 do sum = sum + k end
assert(sum == 55)

local sum2 = 0
for k = 10, 1, -1 do sum2 = sum2 + k end
assert(sum2 == 55)

print("=== generic for ===")
local t = {a=1, b=2, c=3}
local count = 0
for k, v in pairs(t) do count = count + 1 end
assert(count == 3)

print("=== break ===")
local x = 0
for i = 1, 100 do
    x = i
    if i == 5 then break end
end
assert(x == 5)

print("=== goto ===")
local y = 0
::start::
y = y + 1
if y < 3 then goto start end
assert(y == 3)

print("=== local function ===")
local function factorial(n)
    if n <= 1 then return 1 end
    return n * factorial(n - 1)
end
assert(factorial(5) == 120)

print("=== closure ===")
local function make_counter()
    local count = 0
    return function()
        count = count + 1
        return count
    end
end
local counter = make_counter()
assert(counter() == 1)
assert(counter() == 2)
assert(counter() == 3)

print("=== multiple return ===")
local function multi()
    return 1, 2, 3
end
local a, b, c = multi()
assert(a == 1 and b == 2 and c == 3)

print("=== vararg ===")
local function vararg_test(...)
    local args = {...}
    return #args
end
assert(vararg_test(1, 2, 3, 4) == 4)

print("=== tail call ===")
local function tail_sum(n, acc)
    if n == 0 then return acc end
    return tail_sum(n - 1, acc + n)
end
assert(tail_sum(100, 0) == 5050)

print("[PASS] test_control.lua")
