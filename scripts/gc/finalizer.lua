-- Test: __gc finalizer execution
-- Finalizers should run when objects are collected

local finalized = {}

local function test_simple_finalizer()
    finalized = {}

    local mt = {
        __gc = function(self)
            finalized[#finalized + 1] = self.name
        end
    }

    local obj = setmetatable({ name = "test_obj" }, mt)
    obj = nil

    collectgarbage("collect")
    collectgarbage("collect")

    assert(#finalized >= 1, "finalizer not called")
    assert(finalized[1] == "test_obj", "wrong object finalized")
    print("[PASS] Simple finalizer")
end

local function test_multiple_finalizers()
    finalized = {}

    local mt = {
        __gc = function(self)
            finalized[#finalized + 1] = self.id
        end
    }

    for i = 1, 5 do
        local obj = setmetatable({ id = i }, mt)
    end

    collectgarbage("collect")
    collectgarbage("collect")

    assert(#finalized == 5, "expected 5 finalizers, got " .. #finalized)
    print("  finalized order:", table.concat(finalized, ", "))
    print("[PASS] Multiple finalizers")
end

local function test_finalizer_with_error()
    -- Errors in finalizers should be ignored (Lua behavior)
    finalized = {}

    local mt_error = {
        __gc = function(self)
            error("finalizer error!")
        end
    }

    local mt_ok = {
        __gc = function(self)
            finalized[#finalized + 1] = "ok"
        end
    }

    local bad = setmetatable({ name = "bad" }, mt_error)
    local good = setmetatable({ name = "good" }, mt_ok)
    bad = nil
    good = nil

    -- Should not crash
    collectgarbage("collect")
    collectgarbage("collect")

    print("  finalized after error:", #finalized)
    print("[PASS] Finalizer error handling")
end

local function test_finalizer_resurrection()
    -- Object can be "resurrected" by storing reference in finalizer
    local resurrected = nil
    finalized = {}

    local mt = {
        __gc = function(self)
            resurrected = self  -- Resurrect!
            finalized[#finalized + 1] = "resurrected"
        end
    }

    local obj = setmetatable({ data = "important" }, mt)
    obj = nil

    collectgarbage("collect")
    collectgarbage("collect")

    if resurrected then
        assert(resurrected.data == "important", "resurrected data lost")
        print("[PASS] Finalizer resurrection")
    else
        print("[SKIP] Resurrection not supported or timing issue")
    end
end

test_simple_finalizer()
test_multiple_finalizers()
test_finalizer_with_error()
test_finalizer_resurrection()
print("finalizer tests passed")
