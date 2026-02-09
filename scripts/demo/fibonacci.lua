-- Fibonacci Sequence Demo
-- Demonstrates recursion and iteration

-- Recursive version
local function fib_recursive(n)
    if n <= 1 then
        return n
    end
    return fib_recursive(n - 1) + fib_recursive(n - 2)
end

-- Iterative version (faster)
local function fib_iterative(n)
    if n <= 1 then
        return n
    end
    local a, b = 0, 1
    for i = 2, n do
        local tmp = a + b
        a = b
        b = tmp
    end
    return b
end

-- Memoized version
local function fib_memoized()
    local cache = {}
    local function fib(n)
        if cache[n] then
            return cache[n]
        end
        local result
        if n <= 1 then
            result = n
        else
            result = fib(n - 1) + fib(n - 2)
        end
        cache[n] = result
        return result
    end
    return fib
end

print("=== Fibonacci Sequence ===")
print("")

print("First 20 Fibonacci numbers (iterative):")
for i = 0, 19 do
    local n = fib_iterative(i)
    print("F(" .. i .. ") = " .. n)
end

print("")
print("Recursive vs Iterative comparison:")
for i = 0, 15 do
    local r = fib_recursive(i)
    local it = fib_iterative(i)
    assert(r == it, "Mismatch!")
end
print("All values match!")

print("")
print("Memoized Fibonacci (fast for large n):")
local fib = fib_memoized()
for i = 30, 40 do
    print("F(" .. i .. ") = " .. fib(i))
end
