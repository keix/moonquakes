-- Test: Transitive marking through object graph
-- GC must mark: root → table → nested → string

local function test_transitive()
    -- Create object graph
    local root = {
        level1 = {
            level2 = {
                level3 = {
                    value = "deep string"
                }
            }
        }
    }

    -- Force GC
    collectgarbage("collect")

    -- Verify deep value survives
    local deep = root.level1.level2.level3.value
    assert(deep == "deep string", "transitive marking failed: deep string lost")
    print("[PASS] Deep nested table marking")
end

local function test_array_marking()
    -- Array of tables with strings
    local arr = {}
    for i = 1, 100 do
        arr[i] = { name = "item" .. i, data = { x = i, y = i * 2 } }
    end

    collectgarbage("collect")

    -- Verify all items survive
    for i = 1, 100 do
        assert(arr[i].name == "item" .. i, "array marking failed at " .. i)
        assert(arr[i].data.x == i, "nested data lost at " .. i)
    end
    print("[PASS] Array of nested tables marking")
end

local function test_shared_reference()
    -- Multiple tables sharing same nested object
    local shared = { value = "shared data" }
    local t1 = { ref = shared }
    local t2 = { ref = shared }
    local t3 = { ref = shared }

    collectgarbage("collect")

    assert(t1.ref.value == "shared data", "shared ref t1 failed")
    assert(t2.ref.value == "shared data", "shared ref t2 failed")
    assert(t3.ref.value == "shared data", "shared ref t3 failed")
    assert(t1.ref == t2.ref, "shared identity lost")
    print("[PASS] Shared reference marking")
end

test_transitive()
test_array_marking()
test_shared_reference()
print("transitive_mark tests passed")
