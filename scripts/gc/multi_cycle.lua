-- Test: Multiple GC cycles
-- Objects should survive/be collected correctly across many cycles

local function test_survivor_across_cycles()
    local survivor = { name = "immortal", data = {} }

    for cycle = 1, 10 do
        -- Create garbage
        for i = 1, 100 do
            local garbage = { temp = i, cycle = cycle }
        end

        collectgarbage("collect")

        -- Survivor must survive
        assert(survivor.name == "immortal", "survivor lost at cycle " .. cycle)
    end

    print("[PASS] Survivor across 10 cycles")
end

local function test_generational_pattern()
    -- Simulate generational access pattern
    -- Old objects (rarely changing) + young objects (frequently recreated)

    local old_gen = {}
    for i = 1, 50 do
        old_gen[i] = { id = i, created = "old" }
    end

    for round = 1, 5 do
        -- Create young generation
        local young_gen = {}
        for i = 1, 100 do
            young_gen[i] = { id = i, round = round }
        end

        collectgarbage("collect")

        -- Old gen must survive
        for i = 1, 50 do
            assert(old_gen[i].created == "old", "old gen corrupted in round " .. round)
        end

        -- Young gen exists this round
        for i = 1, 100 do
            assert(young_gen[i].round == round, "young gen corrupted")
        end

        -- Young gen goes away at end of loop
    end

    print("[PASS] Generational pattern")
end

local function test_memory_stability()
    -- Memory should be stable after initial warmup
    local anchor = { data = {} }

    -- Warmup
    for i = 1, 5 do
        for j = 1, 100 do
            local t = { x = j }
        end
        collectgarbage("collect")
    end

    local baseline = collectgarbage("count")

    -- Run more cycles
    for i = 1, 10 do
        for j = 1, 100 do
            local t = { x = j }
        end
        collectgarbage("collect")
    end

    local final = collectgarbage("count")
    local diff = math.abs(final - baseline)

    print("  baseline:", baseline, "KB")
    print("  final:", final, "KB")
    print("  diff:", diff, "KB")

    -- Allow small variance (< 10KB)
    assert(diff < 10, "memory not stable: diff = " .. diff .. " KB")
    print("[PASS] Memory stability")
end

local function test_interleaved_alloc_collect()
    -- Interleave allocation and collection
    local results = {}

    for i = 1, 20 do
        -- Allocate
        results[i] = {
            strings = {},
            tables = {}
        }
        for j = 1, 10 do
            results[i].strings[j] = "str_" .. i .. "_" .. j
            results[i].tables[j] = { a = i, b = j }
        end

        -- Collect every 3rd iteration
        if i % 3 == 0 then
            collectgarbage("collect")
        end
    end

    -- Final collection
    collectgarbage("collect")

    -- Verify all results intact
    for i = 1, 20 do
        for j = 1, 10 do
            assert(results[i].strings[j] == "str_" .. i .. "_" .. j,
                   "string lost at " .. i .. "," .. j)
            assert(results[i].tables[j].a == i, "table corrupted at " .. i .. "," .. j)
        end
    end

    print("[PASS] Interleaved alloc/collect")
end

local function test_flip_mark_correctness()
    -- Test that flip mark doesn't cause issues
    -- Object allocated in cycle N should survive cycle N and N+1

    local obj1 = { cycle = 1 }
    collectgarbage("collect")  -- Cycle 1

    local obj2 = { cycle = 2 }
    collectgarbage("collect")  -- Cycle 2

    local obj3 = { cycle = 3 }
    collectgarbage("collect")  -- Cycle 3

    -- All should survive (they're referenced)
    assert(obj1.cycle == 1, "obj1 lost")
    assert(obj2.cycle == 2, "obj2 lost")
    assert(obj3.cycle == 3, "obj3 lost")

    print("[PASS] Flip mark correctness")
end

test_survivor_across_cycles()
test_generational_pattern()
test_memory_stability()
test_interleaved_alloc_collect()
test_flip_mark_correctness()
print("multi_cycle tests passed")
