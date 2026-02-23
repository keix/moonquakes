-- GC Test Suite Runner
-- Runs all GC tests and reports results

print("========================================")
print("       Moonquakes GC Test Suite")
print("========================================")
print()

local tests = {
    { name = "Control Functions", file = "control" },
    { name = "Stop Behavior", file = "stop_behavior" },
    { name = "Transitive Marking", file = "transitive_mark" },
    { name = "Closure/Upvalue", file = "closure_upvalue" },
    { name = "Circular References", file = "circular_ref" },
    { name = "Weak Tables", file = "weak_table" },
    { name = "Finalizers", file = "finalizer" },
    { name = "Stress Test", file = "stress" },
    { name = "Multi-Cycle", file = "multi_cycle" },
}

local passed = 0
local failed = 0
local errors = {}

for _, test in ipairs(tests) do
    print("--- " .. test.name .. " ---")

    -- Use direct dofile instead of pcall to avoid potential GC issues
    dofile("scripts/gc/" .. test.file .. ".lua")
    passed = passed + 1
    print()
end

print("========================================")
print("           Test Results")
print("========================================")
print("Passed: " .. passed .. "/" .. (passed + failed))
print("Failed: " .. failed)

if #errors > 0 then
    print()
    print("Failures:")
    for _, e in ipairs(errors) do
        print("  - " .. e.name .. ": " .. e.error)
    end
end

print("========================================")

if failed == 0 then
    print("All GC tests PASSED!")
else
    print("Some tests FAILED!")
    os.exit(1)
end
