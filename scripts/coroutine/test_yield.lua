-- Yield tests for Moonquakes coroutines
-- Tests: coroutine.yield and resume after yield

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

print("=== Coroutine Yield Tests ===")
print("")

-- ============================================
-- Part 1: Basic yield
-- ============================================
print("-- Basic yield --")

do
    -- Simple yield with no values
    local co = coroutine.create(function()
        coroutine.yield()
        return "done"
    end)

    local ok1 = coroutine.resume(co)
    test("yield suspends", ok1 == true)
    test("after yield is suspended", coroutine.status(co) == "suspended")

    local ok2, result = coroutine.resume(co)
    test("resume after yield succeeds", ok2 == true)
    test("returns final value", result == "done")
    test("after return is dead", coroutine.status(co) == "dead")
end

-- ============================================
-- Part 2: Yield with values
-- ============================================
print("")
print("-- Yield with values --")

do
    -- Yield single value
    local co = coroutine.create(function()
        coroutine.yield(42)
        return "end"
    end)

    local ok, val = coroutine.resume(co)
    test("yield single value", ok == true and val == 42)
end

do
    -- Yield multiple values
    local co = coroutine.create(function()
        coroutine.yield(1, 2, 3)
        return "end"
    end)

    local ok, a, b, c = coroutine.resume(co)
    test("yield multiple values", ok and a == 1 and b == 2 and c == 3)
end

do
    -- Yield string
    local co = coroutine.create(function()
        coroutine.yield("hello")
        return "end"
    end)

    local ok, msg = coroutine.resume(co)
    test("yield string", ok and msg == "hello")
end

-- ============================================
-- Part 3: Resume passes values to yield
-- ============================================
print("")
print("-- Resume passes values to yield --")

do
    -- Resume with single value
    local co = coroutine.create(function()
        local x = coroutine.yield()
        return x * 2
    end)

    coroutine.resume(co)  -- First resume, runs to yield
    local ok, result = coroutine.resume(co, 21)  -- Pass 21 to yield
    test("resume passes single value", ok and result == 42)
end

do
    -- Resume with multiple values
    local co = coroutine.create(function()
        local a, b, c = coroutine.yield()
        return a + b + c
    end)

    coroutine.resume(co)
    local ok, sum = coroutine.resume(co, 10, 20, 30)
    test("resume passes multiple values", ok and sum == 60)
end

-- ============================================
-- Part 4: Multiple yields
-- ============================================
print("")
print("-- Multiple yields --")

do
    local co = coroutine.create(function()
        coroutine.yield(1)
        coroutine.yield(2)
        coroutine.yield(3)
        return 4
    end)

    local ok1, v1 = coroutine.resume(co)
    local ok2, v2 = coroutine.resume(co)
    local ok3, v3 = coroutine.resume(co)
    local ok4, v4 = coroutine.resume(co)

    test("multiple yields work", ok1 and ok2 and ok3 and ok4)
    test("yield sequence correct", v1 == 1 and v2 == 2 and v3 == 3 and v4 == 4)
end

-- ============================================
-- Part 5: Yield in loop
-- ============================================
print("")
print("-- Yield in loop --")

do
    local co = coroutine.create(function()
        for i = 1, 5 do
            coroutine.yield(i)
        end
        return "done"
    end)

    local sum = 0
    for i = 1, 5 do
        local ok, val = coroutine.resume(co)
        if ok then sum = sum + val end
    end

    local ok, final = coroutine.resume(co)
    test("yield in loop", sum == 15)
    test("final return after loop", ok and final == "done")
end

-- ============================================
-- Part 6: Generator pattern
-- ============================================
print("")
print("-- Generator pattern --")

do
    -- Fibonacci generator
    local function fib_gen()
        local a, b = 0, 1
        while true do
            coroutine.yield(a)
            a, b = b, a + b
        end
    end

    local co = coroutine.create(fib_gen)
    local fibs = {}
    for i = 1, 10 do
        local ok, val = coroutine.resume(co)
        if ok then fibs[i] = val end
    end

    -- Fibonacci: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34
    test("fibonacci generator", fibs[1] == 0 and fibs[2] == 1 and fibs[5] == 3 and fibs[10] == 34)
end

-- ============================================
-- Part 7: Yield with state
-- ============================================
print("")
print("-- Yield with state --")

do
    -- Counter that yields and receives increment
    local co = coroutine.create(function()
        local count = 0
        while true do
            local inc = coroutine.yield(count)
            if inc == nil then break end
            count = count + inc
        end
        return count
    end)

    local _, v0 = coroutine.resume(co)      -- Start, get initial count
    local _, v1 = coroutine.resume(co, 5)   -- Add 5
    local _, v2 = coroutine.resume(co, 10)  -- Add 10
    local _, final = coroutine.resume(co, nil)  -- End

    test("stateful coroutine", v0 == 0 and v1 == 5 and v2 == 15)
    test("stateful final value", final == 15)
end

-- ============================================
-- Part 8: isyieldable inside coroutine
-- ============================================
print("")
print("-- isyieldable inside coroutine --")

do
    local inside_result = nil
    local co = coroutine.create(function()
        inside_result = coroutine.isyieldable()
        coroutine.yield()
    end)

    coroutine.resume(co)
    test("isyieldable inside coroutine", inside_result == true)
end

-- ============================================
-- Part 9: Cannot yield from main thread
-- ============================================
print("")
print("-- Cannot yield from main --")

do
    local ok, err = pcall(function()
        coroutine.yield()
    end)
    test("yield from main fails", ok == false)
end

-- ============================================
-- Part 10: Yield preserves stack
-- ============================================
print("")
print("-- Yield preserves stack --")

do
    local co = coroutine.create(function()
        local x = 10
        local y = 20
        coroutine.yield()
        return x + y
    end)

    coroutine.resume(co)
    local ok, result = coroutine.resume(co)
    test("yield preserves locals", ok and result == 30)
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
