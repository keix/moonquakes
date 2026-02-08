-- GC Stress Test Demo
-- Demonstrates garbage collection with various object types

print("=== Moonquakes GC Stress Test ===")
print("")

-- Helper to show memory
local function mem()
    return string.format("%.1f KB", collectgarbage("count"))
end

print("Initial memory: " .. mem())
print("")

-- ============================================================================
-- Test 1: String allocation and collection
-- ============================================================================
print("--- Test 1: String Allocation ---")

local strings = {}
for i = 1, 500 do
    strings[i] = "string_number_" .. i .. "_with_some_extra_padding"
end
print("Created 500 strings: " .. mem())

strings = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Test 2: Table allocation and collection
-- ============================================================================
print("--- Test 2: Table Allocation ---")

local tables = {}
for i = 1, 200 do
    tables[i] = {
        id = i,
        name = "table_" .. i,
        data = {1, 2, 3, 4, 5},
        nested = {
            a = i * 10,
            b = i * 20
        }
    }
end
print("Created 200 nested tables: " .. mem())

-- Verify tables work
local sum = 0
for i = 1, 10 do
    sum = sum + tables[i].id + tables[i].nested.a
end
print("Sum of first 10 table values: " .. sum)

tables = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Test 3: Simple function factories
-- ============================================================================
print("--- Test 3: Function Factories ---")

local function make_adder(n)
    return function(x)
        return x + n
    end
end

local adders = {}
for i = 1, 100 do
    adders[i] = make_adder(i)
end
print("Created 100 adder functions: " .. mem())

-- Verify adders work
sum = 0
for i = 1, 10 do
    sum = sum + adders[i](100)
end
print("Sum of first 10 adders(100): " .. sum)  -- 100+1 + 100+2 + ... + 100+10 = 1055

adders = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Test 4: Churn test (rapid allocation/deallocation)
-- ============================================================================
print("--- Test 4: Allocation Churn ---")

local before_churn = collectgarbage("count")
for round = 1, 5 do
    local temp = {}
    for i = 1, 100 do
        temp[i] = {
            data = "round_" .. round .. "_item_" .. i,
            value = round * 1000 + i
        }
    end
    -- temp goes out of scope each iteration
    collectgarbage()
end
local after_churn = collectgarbage("count")
print("After 5 rounds of 100 allocations: " .. mem())
print("Memory difference: " .. string.format("%.1f KB", after_churn - before_churn))
print("")

-- ============================================================================
-- Test 5: Deep nesting test
-- ============================================================================
print("--- Test 5: Deep Nesting ---")

local function create_chain(depth)
    if depth <= 0 then
        return { value = "leaf" }
    end
    return {
        value = "node_" .. depth,
        child = create_chain(depth - 1)
    }
end

local chains = {}
for i = 1, 20 do
    chains[i] = create_chain(8)
end
print("Created 20 chains of depth 8: " .. mem())

-- Verify chains work
local function count_nodes(node)
    if node.child == nil then
        return 1
    end
    return 1 + count_nodes(node.child)
end
print("Chain 1 has " .. count_nodes(chains[1]) .. " nodes")

chains = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Test 6: Linked list test
-- ============================================================================
print("--- Test 6: Linked Lists ---")

local function create_linked_list(n)
    local head = { value = 1 }
    local current = head
    for i = 2, n do
        current.next = { value = i }
        current = current.next
    end
    return head
end

local lists = {}
for i = 1, 50 do
    lists[i] = create_linked_list(20)
end
print("Created 50 linked lists of length 20: " .. mem())

-- Verify lists work
local function list_sum(head)
    local total = 0
    local current = head
    while current do
        total = total + current.value
        current = current.next
    end
    return total
end
print("List 1 sum: " .. list_sum(lists[1]))  -- 1+2+...+20 = 210

lists = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Test 7: Mixed workload
-- ============================================================================
print("--- Test 7: Mixed Workload ---")

local workspace = {}

-- Create various objects
for i = 1, 100 do
    workspace["str_" .. i] = "value_" .. i
    workspace["tbl_" .. i] = { a = i, b = i * 2 }
end
print("Created mixed workspace: " .. mem())

-- Partial cleanup
for i = 1, 50 do
    workspace["str_" .. i] = nil
    workspace["tbl_" .. i] = nil
end
collectgarbage()
print("After 50% cleanup and GC: " .. mem())

workspace = nil
collectgarbage()
print("After full cleanup and GC: " .. mem())
print("")

-- ============================================================================
-- Test 8: Counter factory test
-- ============================================================================
print("--- Test 8: Counter Factories ---")

local function make_counter(start)
    local count = start
    return function()
        count = count + 1
        return count
    end
end

local counters = {}
for i = 1, 50 do
    counters[i] = make_counter(i * 100)
end
print("Created 50 counter factories: " .. mem())

-- Verify counters work
print("Counter 1: " .. counters[1]() .. ", " .. counters[1]() .. ", " .. counters[1]())
print("Counter 50: " .. counters[50]() .. ", " .. counters[50]() .. ", " .. counters[50]())

counters = nil
collectgarbage()
print("After clearing and GC: " .. mem())
print("")

-- ============================================================================
-- Final Summary
-- ============================================================================
print("--- Final Summary ---")
collectgarbage()
print("Final memory: " .. mem())
print("")
print("=== GC Stress Test Complete ===")
