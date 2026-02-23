-- Test: stop prevents automatic GC

-- Stop GC
collectgarbage("stop")
print("GC stopped")

-- Allocate some tables (would normally trigger GC at threshold)
local count_before = collectgarbage("count")
print("before allocation:", count_before, "KB")

local tables = {}
for i = 1, 1000 do
    tables[i] = { x = i, y = i * 2, name = "table" .. i }
end

local count_after = collectgarbage("count")
print("after allocation:", count_after, "KB")
print("allocated:", count_after - count_before, "KB")

-- Manual collect still works when stopped
collectgarbage("collect")
local count_collected = collectgarbage("count")
print("after manual collect:", count_collected, "KB")

-- Restart and verify
collectgarbage("restart")
print("GC restarted, isrunning:", collectgarbage("isrunning"))

print("stop_behavior test passed")
