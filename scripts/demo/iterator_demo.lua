-- Iterator and closure demo
print("=== Iterator Demo ===")

-- Custom iterator using closures
local function range(start, stop, step)
    step = step or 1
    local current = start - step
    return function()
        current = current + step
        if (step > 0 and current <= stop) or (step < 0 and current >= stop) then
            return current
        end
        return nil
    end
end

-- Test range iterator
print("\n-- Range Iterator --")
local rangeStr = ""
for i in range(1, 5) do
    if rangeStr ~= "" then rangeStr = rangeStr .. ", " end
    rangeStr = rangeStr .. i
end
print("range(1, 5): " .. rangeStr)
-- expect: 1, 2, 3, 4, 5

rangeStr = ""
for i in range(10, 2, -2) do
    if rangeStr ~= "" then rangeStr = rangeStr .. ", " end
    rangeStr = rangeStr .. i
end
print("range(10, 2, -2): " .. rangeStr)
-- expect: 10, 8, 6, 4, 2

-- Array iterator
local function ipairs_manual(t)
    local i = 0
    return function()
        i = i + 1
        if t[i] then
            return i, t[i]
        end
        return nil
    end
end

print("\n-- Array Iterator --")
local arr = {"apple", "banana", "cherry"}
local arrStr = ""
for i, v in ipairs_manual(arr) do
    if arrStr ~= "" then arrStr = arrStr .. ", " end
    arrStr = arrStr .. i .. "=" .. v
end
print("ipairs_manual: " .. arrStr)
-- expect: 1=apple, 2=banana, 3=cherry

-- Stateful counter with closure
local function makeCounter(start)
    local count = start or 0
    return {
        increment = function()
            count = count + 1
            return count
        end,
        decrement = function()
            count = count - 1
            return count
        end,
        get = function()
            return count
        end,
        reset = function()
            count = start or 0
            return count
        end
    }
end

print("\n-- Stateful Counter --")
local counter = makeCounter(10)
print("initial: " .. counter.get())
print("increment: " .. counter.increment())
print("increment: " .. counter.increment())
print("decrement: " .. counter.decrement())
print("reset: " .. counter.reset())
-- expect: 10, 11, 12, 11, 10

-- Fibonacci generator
local function fibonacci()
    local a, b = 0, 1
    return function()
        local result = a
        a, b = b, a + b
        return result
    end
end

print("\n-- Fibonacci Generator --")
local fib = fibonacci()
local fibStr = ""
for i = 1, 10 do
    if fibStr ~= "" then fibStr = fibStr .. ", " end
    fibStr = fibStr .. fib()
end
print("First 10 Fibonacci: " .. fibStr)
-- expect: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34

-- Filter iterator
local function filter(iter, predicate)
    return function()
        while true do
            local value = iter()
            if value == nil then
                return nil
            end
            if predicate(value) then
                return value
            end
        end
    end
end

print("\n-- Filter Iterator --")
local evens = filter(range(1, 10), function(x) return x % 2 == 0 end)
local evensStr = ""
for v in evens do
    if evensStr ~= "" then evensStr = evensStr .. ", " end
    evensStr = evensStr .. v
end
print("Even numbers 1-10: " .. evensStr)
-- expect: 2, 4, 6, 8, 10

-- Map iterator
local function map(iter, transform)
    return function()
        local value = iter()
        if value == nil then
            return nil
        end
        return transform(value)
    end
end

print("\n-- Map Iterator --")
local squares = map(range(1, 5), function(x) return x * x end)
local squaresStr = ""
for v in squares do
    if squaresStr ~= "" then squaresStr = squaresStr .. ", " end
    squaresStr = squaresStr .. v
end
print("Squares 1-5: " .. squaresStr)
-- expect: 1, 4, 9, 16, 25

-- Chained iterators
print("\n-- Chained Iterators --")
local chainedStr = ""
local chained = map(
    filter(range(1, 20), function(x) return x % 3 == 0 end),
    function(x) return x * 2 end
)
for v in chained do
    if chainedStr ~= "" then chainedStr = chainedStr .. ", " end
    chainedStr = chainedStr .. v
end
print("Multiples of 3 (1-20) doubled: " .. chainedStr)
-- expect: 6, 12, 18, 24, 30, 36

print("\n=== Iterator Demo PASSED ===")
