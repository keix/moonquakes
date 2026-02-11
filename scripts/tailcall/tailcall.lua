-- Test tail call optimization

-- Test 1: Simple tail call
local function add1(n)
    return n + 1
end

local function tailAdd1(n)
    return add1(n)  -- This should be a tail call
end

local r1 = tailAdd1(10)
assert(r1 == 11, "tailAdd1 should return 11")

-- Test 2: Tail recursive factorial
local function factorial(n, acc)
    acc = acc or 1
    if n <= 1 then
        return acc
    end
    return factorial(n - 1, n * acc)  -- Tail call
end

local r2 = factorial(5)
assert(r2 == 120, "factorial(5) should be 120")

-- Test 3: Mutual tail recursion
local even, odd

even = function(n)
    if n == 0 then return true end
    return odd(n - 1)  -- Tail call
end

odd = function(n)
    if n == 0 then return false end
    return even(n - 1)  -- Tail call
end

assert(even(10) == true, "10 is even")
assert(odd(10) == false, "10 is not odd")
assert(even(7) == false, "7 is not even")
assert(odd(7) == true, "7 is odd")

-- Test 4: Deep tail recursion (would overflow without TCO)
local function countdown(n)
    if n <= 0 then return "done" end
    return countdown(n - 1)
end

local r4 = countdown(1000)  -- Should not overflow with tail call
assert(r4 == "done", "countdown should complete")

-- Test 5: Non-tail call (for comparison)
local function nonTailFactorial(n)
    if n <= 1 then return 1 end
    return n * nonTailFactorial(n - 1)  -- NOT a tail call (multiplication after)
end

local r5 = nonTailFactorial(5)
assert(r5 == 120, "nonTailFactorial(5) should be 120")

print("tailcall test passed")
