-- Test: Weak table behavior
-- __mode = "k" (weak keys), "v" (weak values), "kv" (both)

local function test_weak_values()
    local cache = setmetatable({}, { __mode = "v" })

    local key1 = "persistent_key"
    local obj = { data = "will be collected" }

    cache[key1] = obj
    cache["another"] = { temp = true }

    -- obj is still referenced
    collectgarbage("collect")
    assert(cache[key1] ~= nil, "weak value collected while referenced")

    -- Drop reference to obj
    obj = nil
    collectgarbage("collect")
    collectgarbage("collect")

    -- Entry may be removed (value was only weakly held)
    -- Note: The key "persistent_key" entry should be gone
    print("  cache[key1] after collect:", cache[key1])
    print("[PASS] Weak values basic test")
end

local function test_weak_keys()
    local registry = setmetatable({}, { __mode = "k" })

    local obj1 = { id = 1 }
    local obj2 = { id = 2 }

    registry[obj1] = "data for obj1"
    registry[obj2] = "data for obj2"

    collectgarbage("collect")
    assert(registry[obj1] == "data for obj1", "weak key entry lost while key referenced")
    assert(registry[obj2] == "data for obj2", "weak key entry lost while key referenced")

    -- Drop reference to obj1
    local saved_obj2 = obj2
    obj1 = nil
    obj2 = nil

    collectgarbage("collect")
    collectgarbage("collect")

    -- obj1 entry should be gone, obj2 still accessible via saved_obj2
    assert(registry[saved_obj2] == "data for obj2", "weak key entry lost for still-referenced key")
    print("[PASS] Weak keys basic test")
end

local function test_weak_both()
    local t = setmetatable({}, { __mode = "kv" })

    local k1 = { key = 1 }
    local v1 = { value = 1 }
    local k2 = { key = 2 }
    local v2 = { value = 2 }

    t[k1] = v1
    t[k2] = v2

    collectgarbage("collect")
    assert(t[k1] ~= nil, "kv entry lost while both referenced")

    -- Keep k2 but drop v2
    v2 = nil
    collectgarbage("collect")
    collectgarbage("collect")

    -- k2 entry should be removed (value is weak and collected)
    print("  t[k2] after dropping v2:", t[k2])
    print("[PASS] Weak keys and values")
end

local function test_weak_table_iteration()
    local weak = setmetatable({}, { __mode = "v" })

    -- Add some entries
    for i = 1, 5 do
        weak[i] = { index = i }
    end

    -- Keep reference to one
    local kept = weak[3]

    collectgarbage("collect")
    collectgarbage("collect")

    -- Count remaining entries
    local count = 0
    for k, v in pairs(weak) do
        count = count + 1
    end

    print("  remaining entries:", count, "(kept index 3)")
    assert(weak[3] ~= nil, "kept entry was collected")
    assert(weak[3].index == 3, "kept entry data corrupted")
    print("[PASS] Weak table iteration")
end

test_weak_values()
test_weak_keys()
test_weak_both()
test_weak_table_iteration()
print("weak_table tests passed")
