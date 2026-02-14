-- Goto and Label Tests
-- Testing goto statements and label definitions

local test_count = 0
local pass_count = 0

local function test(name, condition)
  test_count = test_count + 1
  if condition then
    pass_count = pass_count + 1
    print("  [PASS] " .. name)
  else
    print("  [FAIL] " .. name)
  end
end

-- ============================================================================
-- Part 1: Basic Goto
-- ============================================================================
print("=== Part 1: Basic Goto ===")

-- Simple forward jump
local x = 0
goto skip1
x = 100
::skip1::
x = x + 1
test("Forward jump", x == 1)

-- Multiple labels
local y = 0
goto first
::second::
y = y + 10
goto done1
::first::
y = y + 1
goto second
::done1::
test("Multiple labels", y == 11)

-- ============================================================================
-- Part 2: Backward Jump (Loop Simulation)
-- ============================================================================
print("\n=== Part 2: Backward Jump ===")

-- Simple loop with goto
local sum = 0
local i = 1
::loop1::
if i <= 5 then
  sum = sum + i
  i = i + 1
  goto loop1
end
test("Backward loop", sum == 15)

-- Countdown
local count = 5
local result = ""
::countdown::
if count > 0 then
  result = result .. count
  count = count - 1
  goto countdown
end
test("Countdown loop", result == "54321")

-- ============================================================================
-- Part 3: Nested Structures
-- ============================================================================
print("\n=== Part 3: Nested Structures ===")

-- Goto from inside if
local a = 0
if true then
  a = 1
  goto after_if
  a = 100
end
::after_if::
a = a + 1
test("Goto from if", a == 2)

-- Goto skipping else
local b = 0
if true then
  b = 1
  goto skip_else
else
  b = 100
end
::skip_else::
b = b + 1
test("Skip else branch", b == 2)

-- Goto from nested if
local c = 0
if true then
  if true then
    c = 1
    goto exit_nested
  end
  c = 100
end
::exit_nested::
c = c + 1
test("Exit nested if", c == 2)

-- ============================================================================
-- Part 4: Goto with Loops
-- ============================================================================
print("\n=== Part 4: Goto with Loops ===")

-- Break out of nested loops using goto
local found = false
local fi, fj = 0, 0
for i = 1, 5 do
  for j = 1, 5 do
    if i * j == 12 then
      fi, fj = i, j
      found = true
      goto found_it
    end
  end
end
::found_it::
test("Break nested loops", found and fi == 3 and fj == 4)

-- Continue simulation with goto
local evens = 0
for i = 1, 10 do
  if i % 2 ~= 0 then
    goto continue1
  end
  evens = evens + 1
  ::continue1::
end
test("Continue simulation", evens == 5)

-- ============================================================================
-- Part 5: Goto in Functions
-- ============================================================================
print("\n=== Part 5: Goto in Functions ===")

-- Function with goto (restructured to avoid labels after return)
local function process(n)
  local result = nil
  if n < 0 then
    goto negative
  end
  if n == 0 then
    goto zero
  end
  result = "positive"
  goto done
  ::negative::
  result = "negative"
  goto done
  ::zero::
  result = "zero"
  ::done::
  return result
end

test("Function goto positive", process(5) == "positive")
test("Function goto negative", process(-3) == "negative")
test("Function goto zero", process(0) == "zero")

-- Early return pattern (restructured)
local function find_value(t, target)
  local result1, result2 = nil, "not found"
  for i = 1, #t do
    if t[i] == target then
      result1, result2 = true, "found"
      goto done
    end
  end
  ::done::
  return result1, result2
end

local arr = {1, 2, 3, 4, 5}
local ok1, msg1 = find_value(arr, 3)
local ok2, msg2 = find_value(arr, 10)
test("Find value found", ok1 == true and msg1 == "found")
test("Find value not found", ok2 == nil and msg2 == "not found")

-- ============================================================================
-- Part 6: Complex Control Flow
-- ============================================================================
print("\n=== Part 6: Complex Control Flow ===")

-- State machine using goto (simplified)
local function state_machine(input)
  local pos = 1
  local result = ""
  local ch = ""

  ::state_start::
  if pos > #input then goto state_end end
  ch = string.sub(input, pos, pos)
  pos = pos + 1
  if ch == "a" then
    result = result .. "A"
    goto state_start
  end
  if ch == "b" then
    result = result .. "B"
    goto state_b
  end
  goto state_start

  ::state_b::
  if pos > #input then goto state_end end
  ch = string.sub(input, pos, pos)
  pos = pos + 1
  if ch == "b" then
    result = result .. "B"
    goto state_b
  end
  result = result .. "X"
  goto state_start

  ::state_end::
  return result
end

test("State machine 1", state_machine("aaa") == "AAA")
test("State machine 2", state_machine("abba") == "ABBX")  -- 'a' after 'bb' triggers X, no reprocess
test("State machine 3", state_machine("bbb") == "BBB")

-- ============================================================================
-- Part 7: Goto with Local Variables
-- ============================================================================
print("\n=== Part 7: Goto with Local Variables ===")

-- Variable scope and goto
local outer = 0
do
  local inner = 10
  outer = inner
  goto after_block
  inner = 100  -- Should be skipped
end
::after_block::
test("Goto skips assignment", outer == 10)

-- Multiple blocks
local v1 = 0
local v2 = 0
do
  v1 = 1
  goto block2
end
::block2::
do
  v2 = 2
end
test("Goto between blocks", v1 == 1 and v2 == 2)

-- ============================================================================
-- Part 8: Label Naming
-- ============================================================================
print("\n=== Part 8: Label Naming ===")

-- Various label names
local n1 = 0
goto label_with_underscore
n1 = 100
::label_with_underscore::
n1 = 1
test("Underscore label", n1 == 1)

local n2 = 0
goto label123
n2 = 100
::label123::
n2 = 2
test("Numeric suffix label", n2 == 2)

local n3 = 0
goto UPPERCASE
n3 = 100
::UPPERCASE::
n3 = 3
test("Uppercase label", n3 == 3)

-- ============================================================================
-- Part 9: Goto in While/Repeat
-- ============================================================================
print("\n=== Part 9: Goto in While/Repeat ===")

-- Goto from while loop
local w = 0
local wi = 0
while wi < 10 do
  wi = wi + 1
  if wi == 5 then
    w = wi
    goto exit_while
  end
end
::exit_while::
test("Exit while with goto", w == 5)

-- Goto from repeat loop
local r = 0
local ri = 0
repeat
  ri = ri + 1
  if ri == 3 then
    r = ri
    goto exit_repeat
  end
until ri >= 10
::exit_repeat::
test("Exit repeat with goto", r == 3)

-- ============================================================================
-- Part 10: Error Recovery Pattern
-- ============================================================================
print("\n=== Part 10: Error Recovery Pattern ===")

local function process_with_cleanup(should_fail)
  local resource = "acquired"
  local result = nil

  if should_fail then
    goto cleanup
  end

  -- Normal processing
  result = "success"
  goto done

  ::cleanup::
  resource = "cleaned"
  result = "failed"

  ::done::
  return result, resource
end

local res1, rsc1 = process_with_cleanup(false)
local res2, rsc2 = process_with_cleanup(true)
test("Success path", res1 == "success" and rsc1 == "acquired")
test("Failure path", res2 == "failed" and rsc2 == "cleaned")

-- ============================================================================
-- Part 11: Jump Table Pattern
-- ============================================================================
print("\n=== Part 11: Jump Table Pattern ===")

local function dispatch(op, a, b)
  local result = nil
  if op == "add" then goto op_add end
  if op == "sub" then goto op_sub end
  if op == "mul" then goto op_mul end
  goto op_done

  ::op_add::
  result = a + b
  goto op_done

  ::op_sub::
  result = a - b
  goto op_done

  ::op_mul::
  result = a * b

  ::op_done::
  return result
end

test("Dispatch add", dispatch("add", 3, 4) == 7)
test("Dispatch sub", dispatch("sub", 10, 3) == 7)
test("Dispatch mul", dispatch("mul", 3, 4) == 12)
test("Dispatch unknown", dispatch("div", 10, 2) == nil)

-- ============================================================================
-- Summary
-- ============================================================================
print("\n==================================================")
print("Test Results: " .. pass_count .. "/" .. test_count .. " passed")
if pass_count == test_count then
  print("All tests PASSED!")
else
  print("Some tests FAILED!")
end
print("==================================================")
