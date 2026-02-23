-- Simplified control.lua
local running = collectgarbage("isrunning")
local was_running = collectgarbage("stop")
collectgarbage("restart")
local completed = collectgarbage("step")
collectgarbage("collect")
print("control_simple done")
