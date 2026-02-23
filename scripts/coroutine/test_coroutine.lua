-- Comprehensive coroutine tests for Moonquakes
-- Tests: create, resume, status, running, isyieldable, close

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

print("=== Coroutine Tests ===")
print("")

-- ============================================
-- Part 1: coroutine.running / type
-- ============================================
print("-- coroutine.running --")

local main_co, is_main = coroutine.running()
test("running returns thread", type(main_co) == "thread")
test("main thread is_main = true", is_main == true)
test("type() returns 'thread'", type(main_co) == "thread")

-- ============================================
-- Part 2: coroutine.isyieldable
-- ============================================
print("")
print("-- coroutine.isyieldable --")

test("main thread not yieldable", coroutine.isyieldable() == false)

-- ============================================
-- Part 3: coroutine.create
-- ============================================
print("")
print("-- coroutine.create --")

local function empty_fn() end
local co1 = coroutine.create(empty_fn)
test("create returns thread", type(co1) == "thread")
test("new coroutine != main", co1 ~= main_co)

-- Create with different function types
local function returns_value() return 42 end
local co2 = coroutine.create(returns_value)
test("create with returning function", type(co2) == "thread")

-- Create with closure
local x = 10
local function closure_fn() return x * 2 end
local co3 = coroutine.create(closure_fn)
test("create with closure", type(co3) == "thread")

-- ============================================
-- Part 4: coroutine.status
-- ============================================
print("")
print("-- coroutine.status --")

local co_status = coroutine.create(function() end)
test("new coroutine is suspended", coroutine.status(co_status) == "suspended")
test("main thread is running", coroutine.status(main_co) == "running")

-- ============================================
-- Part 5: coroutine.resume - basic
-- ============================================
print("")
print("-- coroutine.resume (basic) --")

-- Empty function
local co_empty = coroutine.create(function() end)
local ok1 = coroutine.resume(co_empty)
test("resume empty function succeeds", ok1 == true)
test("completed coroutine is dead", coroutine.status(co_empty) == "dead")

-- Return single value
local co_single = coroutine.create(function() return 42 end)
local ok2, val2 = coroutine.resume(co_single)
test("resume returns success", ok2 == true)
test("resume returns value", val2 == 42)

-- Return multiple values
local co_multi = coroutine.create(function() return 1, 2, 3, 4, 5 end)
local ok3, a, b, c, d, e = coroutine.resume(co_multi)
test("multi-value return", ok3 and a == 1 and b == 2 and c == 3 and d == 4 and e == 5)

-- Return nil
local co_nil = coroutine.create(function() return nil end)
local ok4, val4 = coroutine.resume(co_nil)
test("return nil works", ok4 == true and val4 == nil)

-- ============================================
-- Part 6: coroutine.resume - with arguments
-- ============================================
print("")
print("-- coroutine.resume (arguments) --")

-- Single argument
local co_arg1 = coroutine.create(function(x) return x * 2 end)
local ok5, res5 = coroutine.resume(co_arg1, 21)
test("single argument", ok5 and res5 == 42)

-- Multiple arguments
local co_arg2 = coroutine.create(function(a, b, c) return a + b + c end)
local ok6, res6 = coroutine.resume(co_arg2, 10, 20, 30)
test("multiple arguments", ok6 and res6 == 60)

-- More args than params (extras ignored)
local co_arg3 = coroutine.create(function(a) return a end)
local ok7, res7 = coroutine.resume(co_arg3, 100, 200, 300)
test("extra args ignored", ok7 and res7 == 100)

-- Fewer args than params (nil padding)
local co_arg4 = coroutine.create(function(a, b, c) return a, b, c end)
local ok8, r1, r2, r3 = coroutine.resume(co_arg4, 5)
test("missing args are nil", ok8 and r1 == 5 and r2 == nil and r3 == nil)

-- ============================================
-- Part 7: coroutine.resume - error handling
-- ============================================
print("")
print("-- coroutine.resume (errors) --")

-- Runtime error
local co_err1 = coroutine.create(function() error("test error") end)
local ok9, err9 = coroutine.resume(co_err1)
test("error returns false", ok9 == false)
test("error message is string", type(err9) == "string")
test("errored coroutine is dead", coroutine.status(co_err1) == "dead")

-- Cannot resume dead coroutine
local ok10, err10 = coroutine.resume(co_err1)
test("cannot resume dead", ok10 == false)

-- Cannot resume running coroutine (main)
local ok11, err11 = coroutine.resume(main_co)
test("cannot resume running", ok11 == false)

-- ============================================
-- Part 8: coroutine.close
-- ============================================
print("")
print("-- coroutine.close --")

-- Close suspended coroutine
local co_close1 = coroutine.create(function() return 1 end)
local close_ok1 = coroutine.close(co_close1)
test("close suspended succeeds", close_ok1 == true)
test("closed becomes dead", coroutine.status(co_close1) == "dead")

-- Resume closed coroutine fails
local ok12, err12 = coroutine.resume(co_close1)
test("cannot resume closed", ok12 == false)

-- Close dead coroutine (already dead)
local co_close2 = coroutine.create(function() end)
coroutine.resume(co_close2)
local close_ok2 = coroutine.close(co_close2)
test("close dead succeeds", close_ok2 == true)

-- ============================================
-- Part 9: Complex scenarios
-- ============================================
print("")
print("-- Complex scenarios --")

-- Recursive function in coroutine
local function fib(n)
    if n <= 1 then return n end
    return fib(n-1) + fib(n-2)
end
local co_fib = coroutine.create(fib)
local ok13, fib10 = coroutine.resume(co_fib, 10)
test("fibonacci(10) = 55", ok13 and fib10 == 55)

-- Table operations in coroutine
local co_table = coroutine.create(function()
    local t = {}
    for i = 1, 10 do
        t[i] = i * i
    end
    local sum = 0
    for _, v in ipairs(t) do
        sum = sum + v
    end
    return sum
end)
local ok14, sum14 = coroutine.resume(co_table)
test("table sum of squares", ok14 and sum14 == 385) -- 1+4+9+16+25+36+49+64+81+100

-- Closure capturing outer variables
local multiplier = 7
local co_closure = coroutine.create(function(n)
    return n * multiplier
end)
local ok15, res15 = coroutine.resume(co_closure, 6)
test("closure captures outer var", ok15 and res15 == 42)

-- String operations in coroutine
local co_string = coroutine.create(function(s)
    return string.upper(s) .. "!"
end)
local ok16, res16 = coroutine.resume(co_string, "hello")
test("string operations", ok16 and res16 == "HELLO!")

-- Nested function calls
local co_nested = coroutine.create(function(n)
    local function double(x) return x * 2 end
    local function triple(x) return x * 3 end
    return double(triple(n))
end)
local ok17, res17 = coroutine.resume(co_nested, 5)
test("nested function calls", ok17 and res17 == 30)

-- Multiple coroutines
local results = {}
for i = 1, 5 do
    local co = coroutine.create(function(x) return x * x end)
    local ok, res = coroutine.resume(co, i)
    if ok then results[i] = res end
end
test("multiple coroutines", results[1] == 1 and results[2] == 4 and results[3] == 9 and results[4] == 16 and results[5] == 25)

-- ============================================
-- Part 10: API error cases
-- ============================================
print("")
print("-- API error cases --")

-- create with non-function
local create_ok, create_err = pcall(function()
    coroutine.create(42)
end)
test("create rejects non-function", create_ok == false)

local create_ok2, create_err2 = pcall(function()
    coroutine.create("not a function")
end)
test("create rejects string", create_ok2 == false)

local create_ok3, create_err3 = pcall(function()
    coroutine.create(nil)
end)
test("create rejects nil", create_ok3 == false)

-- status with non-thread
local status_ok, status_err = pcall(function()
    coroutine.status(42)
end)
test("status rejects non-thread", status_ok == false)

local status_ok2, status_err2 = pcall(function()
    coroutine.status("not a thread")
end)
test("status rejects string", status_ok2 == false)

-- close with non-thread
local close_ok, close_err = pcall(function()
    coroutine.close(42)
end)
test("close rejects non-thread", close_ok == false)

-- resume with non-thread
local resume_ok, resume_err = pcall(function()
    coroutine.resume(42)
end)
test("resume rejects non-thread", resume_ok == false)

-- ============================================
-- Part 11: Nested coroutine creation
-- ============================================
print("")
print("-- Nested coroutine creation --")

-- Create coroutine inside coroutine
local outer_co = coroutine.create(function()
    local inner_co = coroutine.create(function(x)
        return x * 10
    end)
    local ok, res = coroutine.resume(inner_co, 5)
    return ok, res
end)
local outer_ok, inner_ok, inner_res = coroutine.resume(outer_co)
test("nested create succeeds", outer_ok == true)
test("nested resume succeeds", inner_ok == true)
test("nested returns value", inner_res == 50)

-- Multiple levels of nesting
local level3 = coroutine.create(function()
    local level2 = coroutine.create(function()
        local level1 = coroutine.create(function()
            return "deep"
        end)
        local ok, res = coroutine.resume(level1)
        return res .. "er"
    end)
    local ok, res = coroutine.resume(level2)
    return res .. "est"
end)
local ok_deep, res_deep = coroutine.resume(level3)
test("3-level nesting", ok_deep and res_deep == "deeperest")

-- ============================================
-- Part 12: pcall/xpcall in coroutine
-- ============================================
print("")
print("-- pcall/xpcall in coroutine --")

-- pcall success inside coroutine
local co_pcall1 = coroutine.create(function()
    local ok, res = pcall(function() return 42 end)
    return ok, res
end)
local ok_p1, pcall_ok, pcall_res = coroutine.resume(co_pcall1)
test("pcall success in coroutine", ok_p1 and pcall_ok and pcall_res == 42)

-- pcall catches error inside coroutine
local co_pcall2 = coroutine.create(function()
    local ok, err = pcall(function() error("inner error") end)
    return ok, type(err)
end)
local ok_p2, caught, err_type = coroutine.resume(co_pcall2)
test("pcall catches error in coroutine", ok_p2 and caught == false and err_type == "string")

-- xpcall with handler inside coroutine
local handler_called = false
local co_xpcall = coroutine.create(function()
    local ok = xpcall(function()
        error("xpcall error")
    end, function(err)
        handler_called = true
        return "handled: " .. tostring(err)
    end)
    return ok
end)
local ok_x, xpcall_ok = coroutine.resume(co_xpcall)
test("xpcall in coroutine", ok_x and xpcall_ok == false)

-- ============================================
-- Part 13: Many arguments to coroutine
-- ============================================
print("")
print("-- Many arguments to coroutine --")

-- Function receiving many arguments
local co_many = coroutine.create(function(a, b, c, d, e)
    return a + b + c + d + e
end)
local ok_many, sum_many = coroutine.resume(co_many, 1, 2, 3, 4, 5)
test("sum of 5 args", ok_many and sum_many == 15)

-- Partial arguments (some nil)
local co_partial = coroutine.create(function(a, b, c)
    if b == nil and c == nil then
        return a * 10
    end
    return -1
end)
local ok_part, res_part = coroutine.resume(co_partial, 7)
test("partial args (nil padding)", ok_part and res_part == 70)

-- ============================================
-- Part 14: Upvalues and coroutines
-- ============================================
print("")
print("-- Upvalues and coroutines --")

-- Shared upvalue between coroutines
local shared_counter = 0
local co_up1 = coroutine.create(function()
    shared_counter = shared_counter + 1
    return shared_counter
end)
local co_up2 = coroutine.create(function()
    shared_counter = shared_counter + 10
    return shared_counter
end)

local ok_u1, r1 = coroutine.resume(co_up1)
local ok_u2, r2 = coroutine.resume(co_up2)
test("shared upvalue modified", ok_u1 and ok_u2 and r1 == 1 and r2 == 11)
test("shared counter value", shared_counter == 11)

-- ============================================
-- Part 15: Edge cases (reusing variables to save stack)
-- ============================================
print("")
print("-- Edge cases --")

do
    -- No arguments to resume
    local co = coroutine.create(function() return "ok" end)
    local ok, res = coroutine.resume(co)
    test("resume with no extra args", ok and res == "ok")
end

do
    -- Return boolean values
    local co = coroutine.create(function() return true, false end)
    local ok, t, f = coroutine.resume(co)
    test("return booleans", ok and t == true and f == false)
end

do
    -- Return mixed types
    local co = coroutine.create(function() return 1, "two", true end)
    local ok, m1, m2, m3 = coroutine.resume(co)
    test("return mixed types", ok and m1 == 1 and m2 == "two" and m3 == true)
end

do
    -- Large computation
    local co = coroutine.create(function()
        local sum = 0
        for i = 1, 1000 do
            sum = sum + i
        end
        return sum
    end)
    local ok, sum = coroutine.resume(co)
    test("large computation", ok and sum == 500500)
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
