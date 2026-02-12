-- Test __gc metamethod (garbage collection finalizer)

gc_called = false
gc_value = nil

local function create_finalizable()
    local t = {}
    setmetatable(t, {
        __gc = function(obj)
            gc_called = true
            gc_value = "finalized"
        end
    })
    t.data = "test"
    return t
end

-- Create object in local scope
do
    local obj = create_finalizable()
end
-- Force GC
collectgarbage()
collectgarbage()

assert(gc_called == true, "Expected __gc to be called")
assert(gc_value == "finalized", "Expected gc_value to be 'finalized'")

-- Multiple finalizers
local finalizer_count = 0
for i = 1, 3 do
    local t = setmetatable({id = i}, {
        __gc = function(obj)
            finalizer_count = finalizer_count + 1
        end
    })
end
collectgarbage()
collectgarbage()
assert(finalizer_count == 3, "Expected 3 finalizers to run")

-- Finalizer on reachable object (should NOT be called)
local reachable_gc = false
local reachable = setmetatable({}, {
    __gc = function(obj)
        reachable_gc = true
    end
})
collectgarbage()
collectgarbage()
assert(reachable_gc == false, "__gc should not be called on reachable objects")

print("metamethod_gc: PASSED")
