-- Comprehensive Demo Script for Moonquakes
-- Exercises many Lua features to help find bugs

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
-- Part 1: Simple Object System with Metatables
-- ============================================================================
print("=== Part 1: Object System ===")

local Object = {}
Object.__index = Object

function Object:new(data)
  local obj = data or {}
  setmetatable(obj, self)
  return obj
end

function Object:extend()
  local cls = {}
  cls.__index = cls
  setmetatable(cls, { __index = self })
  return cls
end

-- Test basic object creation
local obj1 = Object:new({ value = 42 })
test("Object creation", obj1.value == 42)

-- Test inheritance
local Animal = Object:extend()
function Animal:speak()
  return "..."
end

local Dog = Animal:extend()
function Dog:speak()
  return "Woof!"
end

local Cat = Animal:extend()
function Cat:speak()
  return "Meow!"
end

local dog = Dog:new({ name = "Rex" })
local cat = Cat:new({ name = "Whiskers" })

test("Inheritance - dog speaks", dog:speak() == "Woof!")
test("Inheritance - cat speaks", cat:speak() == "Meow!")
test("Inheritance - dog name", dog.name == "Rex")

-- ============================================================================
-- Part 2: Functional Collection Operations
-- ============================================================================
print("\n=== Part 2: Functional Collections ===")

local List = {}

function List.new(...)
  local items = {...}
  return items
end

function List.map(t, fn)
  local result = {}
  for i = 1, #t do
    result[i] = fn(t[i], i)
  end
  return result
end

function List.filter(t, pred)
  local result = {}
  for i = 1, #t do
    if pred(t[i], i) then
      result[#result + 1] = t[i]
    end
  end
  return result
end

function List.reduce(t, fn, init)
  local acc = init
  for i = 1, #t do
    acc = fn(acc, t[i], i)
  end
  return acc
end

function List.each(t, fn)
  for i = 1, #t do
    fn(t[i], i)
  end
end

-- Test map
local numbers = List.new(1, 2, 3, 4, 5)
local doubled = List.map(numbers, function(x) return x * 2 end)
test("Map doubles values", doubled[1] == 2 and doubled[3] == 6 and doubled[5] == 10)

-- Test filter
local evens = List.filter(numbers, function(x) return x % 2 == 0 end)
test("Filter even numbers", #evens == 2 and evens[1] == 2 and evens[2] == 4)

-- Test reduce
local sum = List.reduce(numbers, function(acc, x) return acc + x end, 0)
test("Reduce sum", sum == 15)

-- Test chaining
local result = List.reduce(
  List.filter(
    List.map(numbers, function(x) return x * 3 end),
    function(x) return x > 6 end
  ),
  function(acc, x) return acc + x end,
  0
)
test("Chained operations", result == 9 + 12 + 15)  -- 36

-- ============================================================================
-- Part 3: Closure and Upvalue Tests
-- ============================================================================
print("\n=== Part 3: Closures and Upvalues ===")

-- Counter factory
local function makeCounter(start)
  local count = start or 0
  return {
    inc = function() count = count + 1; return count end,
    dec = function() count = count - 1; return count end,
    get = function() return count end,
    set = function(v) count = v end
  }
end

local counter1 = makeCounter(0)
local counter2 = makeCounter(100)

test("Counter independent 1", counter1.inc() == 1)
test("Counter independent 2", counter2.inc() == 101)
test("Counter inc multiple", counter1.inc() == 2 and counter1.inc() == 3)
test("Counter dec", counter1.dec() == 2)
counter1.set(50)
test("Counter set/get", counter1.get() == 50)

-- Nested closures
local function outer(x)
  local function middle(y)
    local function inner(z)
      return x + y + z
    end
    return inner
  end
  return middle
end

local fn = outer(1)(2)
test("Nested closures", fn(3) == 6)

-- Shared upvalue modification
local function makeSharedCounters()
  local shared = 0
  return {
    a = function() shared = shared + 1; return shared end,
    b = function() shared = shared + 10; return shared end,
    get = function() return shared end
  }
end

local shared = makeSharedCounters()
shared.a()
shared.b()
shared.a()
test("Shared upvalue", shared.get() == 12)

-- ============================================================================
-- Part 4: Recursion Tests
-- ============================================================================
print("\n=== Part 4: Recursion ===")

-- Factorial
local function factorial(n)
  if n <= 1 then return 1 end
  return n * factorial(n - 1)
end

test("Factorial 5", factorial(5) == 120)
test("Factorial 10", factorial(10) == 3628800)

-- Fibonacci with memoization
local function memoFib()
  local cache = {}
  local function fib(n)
    if cache[n] then return cache[n] end
    if n <= 2 then return 1 end
    local result = fib(n - 1) + fib(n - 2)
    cache[n] = result
    return result
  end
  return fib
end

local fib = memoFib()
test("Fibonacci 10", fib(10) == 55)
test("Fibonacci 20", fib(20) == 6765)

-- Mutual recursion
local isEven, isOdd

isEven = function(n)
  if n == 0 then return true end
  return isOdd(n - 1)
end

isOdd = function(n)
  if n == 0 then return false end
  return isEven(n - 1)
end

test("Mutual recursion isEven(10)", isEven(10) == true)
test("Mutual recursion isOdd(7)", isOdd(7) == true)

-- ============================================================================
-- Part 5: String Operations
-- ============================================================================
print("\n=== Part 5: String Operations ===")

-- Simple tokenizer
local function tokenize(str)
  local tokens = {}
  local current = ""

  for i = 1, #str do
    local c = string.sub(str, i, i)
    if c == " " or c == "\t" or c == "\n" then
      if #current > 0 then
        tokens[#tokens + 1] = current
        current = ""
      end
    else
      current = current .. c
    end
  end

  if #current > 0 then
    tokens[#tokens + 1] = current
  end

  return tokens
end

local tokens = tokenize("hello world  foo   bar")
test("Tokenize count", #tokens == 4)
test("Tokenize content", tokens[1] == "hello" and tokens[4] == "bar")

-- String builder pattern
local function StringBuilder()
  local parts = {}
  return {
    append = function(s)
      parts[#parts + 1] = s
      return parts  -- return self for chaining
    end,
    build = function()
      local result = ""
      for i = 1, #parts do
        result = result .. parts[i]
      end
      return result
    end,
    length = function()
      local len = 0
      for i = 1, #parts do
        len = len + #parts[i]
      end
      return len
    end
  }
end

local sb = StringBuilder()
sb.append("Hello")
sb.append(", ")
sb.append("World")
sb.append("!")
test("StringBuilder build", sb.build() == "Hello, World!")
test("StringBuilder length", sb.length() == 13)

-- ============================================================================
-- Part 6: Error Handling with pcall
-- ============================================================================
print("\n=== Part 6: Error Handling ===")

-- Basic pcall success
local ok, result = pcall(function()
  return 42
end)
test("pcall success", ok == true and result == 42)

-- pcall with error
local ok2, err = pcall(function()
  error("test error")
end)
test("pcall catches error", ok2 == false)

-- Nested pcall
local function riskyOperation(should_fail)
  if should_fail then
    error("operation failed")
  end
  return "success"
end

local function safeRiskyOperation(should_fail)
  local ok, result = pcall(riskyOperation, should_fail)
  if ok then
    return result
  else
    return "fallback"
  end
end

test("Nested pcall success", safeRiskyOperation(false) == "success")
test("Nested pcall fallback", safeRiskyOperation(true) == "fallback")

-- ============================================================================
-- Part 7: Multiple Return Values and Varargs
-- ============================================================================
print("\n=== Part 7: Multiple Returns and Varargs ===")

local function multiReturn()
  return 1, 2, 3
end

local a, b, c = multiReturn()
test("Multiple return values", a == 1 and b == 2 and c == 3)

local function sumVararg(...)
  local args = {...}
  local total = 0
  for i = 1, #args do
    total = total + args[i]
  end
  return total, #args
end

local total, count = sumVararg(1, 2, 3, 4, 5)
test("Vararg sum", total == 15)
test("Vararg count", count == 5)

-- Vararg forwarding
local function wrapper(...)
  return sumVararg(...)
end

local t2, c2 = wrapper(10, 20, 30)
test("Vararg forwarding", t2 == 60 and c2 == 3)

-- Select with varargs
local function selectTest(...)
  local first = select(1, ...)
  local count = select("#", ...)
  return first, count
end

local f, n = selectTest("a", "b", "c", "d")
test("Select first", f == "a")
test("Select count", n == 4)

-- ============================================================================
-- Part 8: Table Operations
-- ============================================================================
print("\n=== Part 8: Table Operations ===")

-- Array operations
local arr = {10, 20, 30, 40, 50}
test("Array length", #arr == 5)
test("Array access", arr[3] == 30)

-- Table insert/remove simulation
local function tableInsert(t, pos, value)
  if value == nil then
    value = pos
    pos = #t + 1
  end
  for i = #t, pos, -1 do
    t[i + 1] = t[i]
  end
  t[pos] = value
end

local function tableRemove(t, pos)
  pos = pos or #t
  local val = t[pos]
  for i = pos, #t - 1 do
    t[i] = t[i + 1]
  end
  t[#t] = nil
  return val
end

local testArr = {1, 2, 3}
tableInsert(testArr, 2, 99)
test("Table insert", testArr[2] == 99 and testArr[3] == 2 and #testArr == 4)

local removed = tableRemove(testArr, 2)
test("Table remove", removed == 99 and testArr[2] == 2 and #testArr == 3)

-- Hash table iteration
local hash = { a = 1, b = 2, c = 3 }
local keyCount = 0
local valueSum = 0
for k, v in pairs(hash) do
  keyCount = keyCount + 1
  valueSum = valueSum + v
end
test("Hash iteration count", keyCount == 3)
test("Hash iteration sum", valueSum == 6)

-- ============================================================================
-- Part 9: Metamethods
-- ============================================================================
print("\n=== Part 9: Metamethods ===")

-- __index for defaults
local defaults = { x = 0, y = 0, z = 0 }
local point = setmetatable({ x = 10 }, { __index = defaults })
test("__index default", point.y == 0)
test("__index override", point.x == 10)

-- __newindex for tracking
local tracked = {}
local writes = {}
setmetatable(tracked, {
  __newindex = function(t, k, v)
    writes[#writes + 1] = { key = k, value = v }
    rawset(t, k, v)
  end
})
tracked.foo = 1
tracked.bar = 2
test("__newindex tracking", #writes == 2)
test("__newindex values", writes[1].key == "foo" and writes[2].value == 2)

-- __call for callable tables
local callable = setmetatable({}, {
  __call = function(self, x, y)
    return x + y
  end
})
test("__call", callable(3, 4) == 7)

-- __tostring
local Point = {}
Point.__index = Point
Point.__tostring = function(self)
  return "Point(" .. self.x .. ", " .. self.y .. ")"
end

function Point.new(x, y)
  return setmetatable({ x = x, y = y }, Point)
end

local p = Point.new(5, 10)
test("__tostring", tostring(p) == "Point(5, 10)")

-- ============================================================================
-- Part 10: Complex Data Structure - Binary Tree
-- ============================================================================
print("\n=== Part 10: Binary Tree ===")

local Tree = {}

function Tree.new(value)
  return { value = value, left = nil, right = nil }
end

function Tree.insert(node, value)
  if node == nil then
    return Tree.new(value)
  end
  if value < node.value then
    node.left = Tree.insert(node.left, value)
  else
    node.right = Tree.insert(node.right, value)
  end
  return node
end

function Tree.contains(node, value)
  if node == nil then return false end
  if value == node.value then return true end
  if value < node.value then
    return Tree.contains(node.left, value)
  else
    return Tree.contains(node.right, value)
  end
end

function Tree.inorder(node, result)
  result = result or {}
  if node ~= nil then
    Tree.inorder(node.left, result)
    result[#result + 1] = node.value
    Tree.inorder(node.right, result)
  end
  return result
end

function Tree.size(node)
  if node == nil then return 0 end
  return 1 + Tree.size(node.left) + Tree.size(node.right)
end

-- Build a tree
local root = nil
local values = {5, 3, 7, 1, 9, 4, 6, 8, 2}
for i = 1, #values do
  root = Tree.insert(root, values[i])
end

test("Tree size", Tree.size(root) == 9)
test("Tree contains 7", Tree.contains(root, 7) == true)
test("Tree contains 10", Tree.contains(root, 10) == false)

local sorted = Tree.inorder(root)
test("Tree inorder first", sorted[1] == 1)
test("Tree inorder last", sorted[9] == 9)

-- Verify sorted order
local isSorted = true
for i = 2, #sorted do
  if sorted[i] < sorted[i-1] then
    isSorted = false
    break
  end
end
test("Tree inorder sorted", isSorted)

-- ============================================================================
-- Part 11: State Machine
-- ============================================================================
print("\n=== Part 11: State Machine ===")

local function createStateMachine(initial)
  local state = initial
  local transitions = {}
  local onEnter = {}
  local onExit = {}

  return {
    addTransition = function(from, event, to)
      transitions[from] = transitions[from] or {}
      transitions[from][event] = to
    end,

    onEnter = function(s, fn)
      onEnter[s] = fn
    end,

    onExit = function(s, fn)
      onExit[s] = fn
    end,

    send = function(event)
      local trans = transitions[state]
      if trans and trans[event] then
        local newState = trans[event]
        if onExit[state] then onExit[state]() end
        state = newState
        if onEnter[state] then onEnter[state]() end
        return true
      end
      return false
    end,

    getState = function()
      return state
    end
  }
end

local sm = createStateMachine("idle")
sm.addTransition("idle", "start", "running")
sm.addTransition("running", "pause", "paused")
sm.addTransition("paused", "resume", "running")
sm.addTransition("running", "stop", "idle")
sm.addTransition("paused", "stop", "idle")

test("State machine initial", sm.getState() == "idle")
sm.send("start")
test("State machine transition", sm.getState() == "running")
sm.send("pause")
test("State machine pause", sm.getState() == "paused")
sm.send("resume")
test("State machine resume", sm.getState() == "running")

local invalidResult = sm.send("invalid_event")
test("State machine invalid event", invalidResult == false and sm.getState() == "running")

-- ============================================================================
-- Part 12: Iterator Patterns
-- ============================================================================
print("\n=== Part 12: Iterator Patterns ===")

-- Range iterator
local function range(start, stop, step)
  step = step or 1
  local i = start - step
  return function()
    i = i + step
    if (step > 0 and i <= stop) or (step < 0 and i >= stop) then
      return i
    end
    return nil
  end
end

local rangeSum = 0
for v in range(1, 5) do
  rangeSum = rangeSum + v
end
test("Range iterator", rangeSum == 15)

local reverseSum = 0
for v in range(5, 1, -1) do
  reverseSum = reverseSum + v
end
test("Reverse range", reverseSum == 15)

-- Custom pairs-like iterator
local function orderedPairs(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  -- Simple sort (bubble sort for demo)
  for i = 1, #keys - 1 do
    for j = 1, #keys - i do
      if keys[j] > keys[j + 1] then
        keys[j], keys[j + 1] = keys[j + 1], keys[j]
      end
    end
  end
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

local orderedKeys = {}
for k, v in orderedPairs({ c = 3, a = 1, b = 2 }) do
  orderedKeys[#orderedKeys + 1] = k
end
test("Ordered pairs", orderedKeys[1] == "a" and orderedKeys[2] == "b" and orderedKeys[3] == "c")

-- ============================================================================
-- Part 13: Deep Copy (simplified - no cycle detection)
-- ============================================================================
print("\n=== Part 13: Deep Copy ===")

-- Simple deep copy without cycle detection (uses string keys only)
local function deepCopy(obj)
  if type(obj) ~= "table" then return obj end
  local copy = {}
  for k, v in pairs(obj) do
    copy[k] = deepCopy(v)
  end
  return copy
end

-- Simple deep equals (assumes no cycles)
local function deepEquals(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end

  for k, v in pairs(a) do
    if not deepEquals(v, b[k]) then return false end
  end
  for k, v in pairs(b) do
    if a[k] == nil then return false end
  end

  return true
end

local original = {
  name = "test",
  nested = { a = 1, b = { c = 2 } },
  arr = { 1, 2, 3 }
}

local copy = deepCopy(original)
test("Deep copy independence", original ~= copy)
test("Deep copy equality", deepEquals(original, copy))

copy.nested.b.c = 999
test("Deep copy no reference sharing", original.nested.b.c == 2)

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
