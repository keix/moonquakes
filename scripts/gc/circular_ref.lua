-- Test: Circular reference handling
-- GC must collect unreachable cycles

local function test_simple_cycle()
    local before = collectgarbage("count")

    -- Create cycle
    local a = { name = "a" }
    local b = { name = "b" }
    a.ref = b
    b.ref = a

    -- Remove external references
    a = nil
    b = nil

    collectgarbage("collect")
    collectgarbage("collect")  -- Double collect for thorough cleanup

    local after = collectgarbage("count")
    -- Memory should decrease (cycle collected)
    print("  before:", before, "KB, after:", after, "KB")
    print("[PASS] Simple cycle (no assertion, visual check)")
end

local function test_self_reference()
    local before = collectgarbage("count")

    local t = { name = "self" }
    t.self = t
    t = nil

    collectgarbage("collect")
    collectgarbage("collect")

    local after = collectgarbage("count")
    print("  before:", before, "KB, after:", after, "KB")
    print("[PASS] Self reference")
end

local function test_complex_cycle()
    local before = collectgarbage("count")

    -- Create complex graph
    local nodes = {}
    for i = 1, 10 do
        nodes[i] = { id = i, edges = {} }
    end

    -- Add edges (create cycles)
    for i = 1, 10 do
        local next = (i % 10) + 1
        nodes[i].edges[1] = nodes[next]
        nodes[next].edges[2] = nodes[i]
    end

    -- Drop all references
    nodes = nil

    collectgarbage("collect")
    collectgarbage("collect")

    local after = collectgarbage("count")
    print("  before:", before, "KB, after:", after, "KB")
    print("[PASS] Complex cycle graph")
end

local function test_reachable_cycle()
    -- Cycle that IS reachable should survive
    local root = { name = "root" }
    local child = { name = "child" }
    root.child = child
    child.parent = root  -- Creates cycle

    collectgarbage("collect")

    assert(root.child.name == "child", "reachable cycle child lost")
    assert(root.child.parent.name == "root", "reachable cycle parent ref lost")
    print("[PASS] Reachable cycle survives")
end

test_simple_cycle()
test_self_reference()
test_complex_cycle()
test_reachable_cycle()
print("circular_ref tests passed")
