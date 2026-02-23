-- GC control test

-- isrunning (should be true initially)
local running = collectgarbage("isrunning")
print("isrunning:", running)

-- count (memory in KB)
local kb = collectgarbage("count")
print("count:", kb, "KB")

-- stop (returns previous state)
local was_running = collectgarbage("stop")
print("stop returned:", was_running)

-- isrunning after stop (should be false)
running = collectgarbage("isrunning")
print("isrunning after stop:", running)

-- restart
collectgarbage("restart")
running = collectgarbage("isrunning")
print("isrunning after restart:", running)

-- step (performs collection, returns true if completed)
local completed = collectgarbage("step")
print("step completed:", completed)

-- collect (full collection)
collectgarbage("collect")
print("collect: done")

-- final count
kb = collectgarbage("count")
print("final count:", kb, "KB")

print("GC control test passed")
