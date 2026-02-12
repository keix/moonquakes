-- Test goto and label functionality

-- 1. Simple forward jump
local reached_a = false
goto label_a
reached_a = true  -- should be skipped
::label_a::
assert(reached_a == false, "forward jump failed")

-- 2. Multiple labels
local path = ""
goto first
::third::
path = path .. "3"
goto done
::second::
path = path .. "2"
goto third
::first::
path = path .. "1"
goto second
::done::
assert(path == "123", "multiple labels path failed: " .. path)

-- 3. Backward jump (simple loop)
local sum = 0
local i = 1
::add_loop::
sum = sum + i
i = i + 1
if i <= 5 then goto add_loop end
assert(sum == 15, "backward loop sum failed")

-- 4. Nested labels in different scopes
local outer_hit = false
local inner_hit = false
goto outer_label
do
    ::inner_label::
    inner_hit = true
end
::outer_label::
outer_hit = true
assert(outer_hit == true, "outer label failed")
assert(inner_hit == false, "inner label should not be hit")

-- 5. Label after statement on same line style
local x = 0
::inc:: x = x + 1
if x < 3 then goto inc end
assert(x == 3, "inline label failed")

print("goto_label: PASSED")
