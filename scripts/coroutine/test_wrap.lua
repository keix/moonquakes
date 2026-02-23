-- Wrap tests for Moonquakes coroutines
-- Tests: coroutine.wrap

local passed = 0
local failed = 0

local function test(name, condition, msg)
    if condition then
        passed = passed + 1
        print("  [PASS] " .. name)
    else
        failed = failed + 1
        print("  [FAIL] " .. name .. (msg and (": " .. msg) or ""))
    end
end

print("=== Coroutine Wrap Tests ===")
print("")

-- ============================================
-- Part 1: Basic wrap
-- ============================================
print("-- Basic wrap --")

do
    -- Simple function
    local wrapped = coroutine.wrap(function(x)
        return x * 2
    end)
    local result = wrapped(21)
    test("basic wrap returns value", result == 42)
end

do
    -- Multiple return values
    local wrapped = coroutine.wrap(function(a, b)
        return a + b, a - b
    end)
    local sum, diff = wrapped(10, 3)
    test("wrap multiple returns", sum == 13 and diff == 7)
end

-- ============================================
-- Part 2: Wrap with yield
-- ============================================
print("")
print("-- Wrap with yield --")

do
    local wrapped = coroutine.wrap(function()
        coroutine.yield(1)
        coroutine.yield(2)
        return 3
    end)

    local v1 = wrapped()
    local v2 = wrapped()
    local v3 = wrapped()

    test("wrap yield sequence", v1 == 1 and v2 == 2 and v3 == 3)
end

do
    -- Yield with values
    local wrapped = coroutine.wrap(function(x)
        local y = coroutine.yield(x * 2)
        return y + 10
    end)

    local first = wrapped(5)   -- Returns 10 (5 * 2)
    local second = wrapped(100) -- Returns 110 (100 + 10)

    test("wrap passes values through yield", first == 10 and second == 110)
end

-- ============================================
-- Part 3: Generator with wrap
-- ============================================
print("")
print("-- Generator with wrap --")

do
    local function range(n)
        return coroutine.wrap(function()
            for i = 1, n do
                coroutine.yield(i)
            end
        end)
    end

    local sum = 0
    local gen = range(5)
    for i = 1, 5 do
        sum = sum + gen()
    end

    test("generator pattern with wrap", sum == 15)
end

do
    -- Fibonacci generator using wrap
    local function fib_gen()
        return coroutine.wrap(function()
            local a, b = 0, 1
            while true do
                coroutine.yield(a)
                a, b = b, a + b
            end
        end)
    end

    local fib = fib_gen()
    local fibs = {}
    for i = 1, 10 do
        fibs[i] = fib()
    end

    -- Fibonacci: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34
    test("fibonacci with wrap", fibs[1] == 0 and fibs[5] == 3 and fibs[10] == 34)
end

-- ============================================
-- Part 4: Error propagation
-- ============================================
print("")
print("-- Error propagation --")

do
    local wrapped = coroutine.wrap(function()
        error("test error")
    end)

    local ok, err = pcall(wrapped)
    test("wrap propagates errors", ok == false)
end

do
    -- Error after yield
    local wrapped = coroutine.wrap(function()
        coroutine.yield(1)
        error("delayed error")
    end)

    local v1 = wrapped()
    local ok, err = pcall(wrapped)

    test("error after yield propagates", v1 == 1 and ok == false)
end

-- ============================================
-- Part 5: Dead coroutine
-- ============================================
print("")
print("-- Dead coroutine --")

do
    local wrapped = coroutine.wrap(function()
        return "done"
    end)

    wrapped()  -- Completes the coroutine
    local ok, err = pcall(wrapped)  -- Try to call again

    test("calling dead wrapped coroutine errors", ok == false)
end

-- ============================================
-- Part 6: Wrap rejects non-function
-- ============================================
print("")
print("-- Error cases --")

do
    local ok = pcall(function()
        coroutine.wrap(42)
    end)
    test("wrap rejects non-function", ok == false)
end

do
    local ok = pcall(function()
        coroutine.wrap(nil)
    end)
    test("wrap rejects nil", ok == false)
end

-- ============================================
-- Summary
-- ============================================
print("")
print("==================================================")
print(string.format("Test Results: %d/%d passed", passed, passed + failed))
if failed == 0 then
    print("All tests PASSED!")
else
    print(string.format("%d tests FAILED", failed))
end
print("==================================================")
