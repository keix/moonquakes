-- Test: GC stress test
-- High allocation rate with concurrent collection

local function test_allocation_storm()
    local start_mem = collectgarbage("count")

    -- Allocate many small objects
    local alive = {}
    for i = 1, 1000 do
        alive[i] = { x = i, y = i * 2, name = "obj" .. i }
    end

    local peak_mem = collectgarbage("count")

    -- Drop half
    for i = 1, 500 do
        alive[i] = nil
    end

    collectgarbage("collect")

    local after_gc = collectgarbage("count")

    print("  start:", start_mem, "KB")
    print("  peak:", peak_mem, "KB")
    print("  after GC:", after_gc, "KB")

    -- Verify surviving objects
    for i = 501, 1000 do
        assert(alive[i].x == i, "surviving object corrupted at " .. i)
    end

    print("[PASS] Allocation storm")
end

local function test_nested_allocation()
    -- Deep nesting stress test
    local function make_deep(depth)
        if depth == 0 then
            return { leaf = true, data = string.rep("x", 100) }
        end
        return {
            left = make_deep(depth - 1),
            right = make_deep(depth - 1),
            depth = depth
        }
    end

    local tree = make_deep(8)  -- 2^8 = 256 leaves
    collectgarbage("collect")

    -- Verify structure
    local function count_leaves(node)
        if node.leaf then return 1 end
        return count_leaves(node.left) + count_leaves(node.right)
    end

    local leaves = count_leaves(tree)
    assert(leaves == 256, "expected 256 leaves, got " .. leaves)
    print("[PASS] Nested allocation (256 leaves)")
end

local function test_rapid_create_destroy()
    -- Rapidly create and destroy objects
    for round = 1, 10 do
        local temps = {}
        for i = 1, 500 do
            temps[i] = {
                data = string.rep("a", 50),
                nested = { x = i }
            }
        end
        -- All temps go out of scope here
    end

    collectgarbage("collect")

    local mem = collectgarbage("count")
    print("  memory after rapid create/destroy:", mem, "KB")
    print("[PASS] Rapid create/destroy")
end

local function test_string_interning_stress()
    -- Test string interning under GC pressure
    local strings = {}

    for i = 1, 100 do
        local s = "string_" .. i
        strings[i] = s
        -- Create duplicate (should be interned)
        local dup = "string_" .. i
        assert(s == dup, "string interning broken")
    end

    collectgarbage("collect")

    -- Verify strings survived
    for i = 1, 100 do
        assert(strings[i] == "string_" .. i, "interned string lost")
    end

    print("[PASS] String interning under GC")
end

local function test_closure_stress()
    -- Many closures capturing upvalues
    local closures = {}
    local shared_state = { count = 0 }

    for i = 1, 200 do
        local local_val = i
        closures[i] = function()
            shared_state.count = shared_state.count + local_val
            return local_val
        end
    end

    collectgarbage("collect")

    -- Execute all closures
    local sum = 0
    for i = 1, 200 do
        sum = sum + closures[i]()
    end

    assert(sum == 20100, "closure sum wrong: expected 20100, got " .. sum)
    assert(shared_state.count == 20100, "shared state wrong")
    print("[PASS] Closure stress test")
end

test_allocation_storm()
test_nested_allocation()
test_rapid_create_destroy()
test_string_interning_stress()
test_closure_stress()
print("stress tests passed")
