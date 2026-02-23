-- Test: Closure and upvalue marking
-- GC must trace: closure → upvalue → captured value

local function test_simple_closure()
    local captured = "captured string"
    local closure = function()
        return captured
    end

    collectgarbage("collect")

    assert(closure() == "captured string", "simple closure upvalue lost")
    print("[PASS] Simple closure upvalue")
end

local function test_nested_closure()
    local outer = "outer"
    local make_inner = function()
        local inner = "inner"
        return function()
            return outer .. " + " .. inner
        end
    end

    local inner_closure = make_inner()
    collectgarbage("collect")

    assert(inner_closure() == "outer + inner", "nested closure upvalues lost")
    print("[PASS] Nested closure upvalues")
end

local function test_mutable_upvalue()
    local counter = 0
    local inc = function() counter = counter + 1 end
    local get = function() return counter end

    inc()
    inc()
    collectgarbage("collect")
    inc()

    assert(get() == 3, "mutable upvalue failed: expected 3, got " .. get())
    print("[PASS] Mutable upvalue across GC")
end

local function test_closure_chain()
    -- Chain of closures sharing upvalues
    local state = { value = 0 }

    local function add(n)
        return function()
            state.value = state.value + n
            return state.value
        end
    end

    local add1 = add(1)
    local add5 = add(5)
    local add10 = add(10)

    add1()  -- 1
    collectgarbage("collect")
    add5()  -- 6
    collectgarbage("collect")
    add10() -- 16

    assert(state.value == 16, "closure chain failed: expected 16, got " .. state.value)
    print("[PASS] Closure chain with shared state")
end

local function test_closure_in_table()
    local methods = {}

    local function make_counter(start)
        local count = start
        methods.inc = function() count = count + 1 end
        methods.dec = function() count = count - 1 end
        methods.get = function() return count end
    end

    make_counter(10)
    methods.inc()
    methods.inc()
    collectgarbage("collect")
    methods.dec()

    assert(methods.get() == 11, "closure in table failed")
    print("[PASS] Closures stored in table")
end

test_simple_closure()
test_nested_closure()
test_mutable_upvalue()
test_closure_chain()
test_closure_in_table()
print("closure_upvalue tests passed")
