-- Functions Demo
-- Demonstrates structured functions, closures, recursion, and higher-order functions

print("=== Moonquakes Functions Demo ===")
print("")

-- ============================================================================
-- Part 1: Basic Function Patterns
-- ============================================================================
print("--- Part 1: Basic Function Patterns ---")

-- Simple function
local function greet(name)
    return "Hello, " .. name .. "!"
end

print(greet("World"))
print(greet("Lua"))

-- Multiple return values
local function divmod(a, b)
    return math.floor(a / b), a % b
end

local q, r = divmod(17, 5)
print("17 / 5 = " .. q .. " remainder " .. r)

-- Function with default-like behavior
local function power(base, exp)
    if exp == nil then exp = 2 end
    local result = 1
    for i = 1, exp do
        result = result * base
    end
    return result
end

print("power(3) = " .. power(3))
print("power(2, 8) = " .. power(2, 8))
print("")

-- ============================================================================
-- Part 2: Closures and Upvalues
-- ============================================================================
print("--- Part 2: Closures and Upvalues ---")

-- Counter factory (classic closure example)
local function make_counter(start)
    local count = start or 0
    return function()
        count = count + 1
        return count
    end
end

local counter1 = make_counter(0)
local counter2 = make_counter(100)

print("Counter1: " .. counter1() .. ", " .. counter1() .. ", " .. counter1())
print("Counter2: " .. counter2() .. ", " .. counter2() .. ", " .. counter2())

-- Accumulator
local function make_accumulator()
    local sum = 0
    return function(n)
        sum = sum + n
        return sum
    end
end

local acc = make_accumulator()
print("Accumulator: " .. acc(5) .. ", " .. acc(10) .. ", " .. acc(3))

-- Closure capturing multiple values
local function make_range_checker(min, max)
    return function(value)
        return value >= min and value <= max
    end
end

local is_valid_score = make_range_checker(0, 100)
print("Is 75 valid score? " .. tostring(is_valid_score(75)))
print("Is 150 valid score? " .. tostring(is_valid_score(150)))
print("")

-- ============================================================================
-- Part 3: Recursion
-- ============================================================================
print("--- Part 3: Recursion ---")

-- Factorial (simple recursion)
local function factorial(n)
    if n <= 1 then
        return 1
    end
    return n * factorial(n - 1)
end

print("5! = " .. factorial(5))
print("10! = " .. factorial(10))

-- Fibonacci (tree recursion, creates many call frames)
local function fib(n)
    if n <= 2 then
        return 1
    end
    return fib(n - 1) + fib(n - 2)
end

print("fib(10) = " .. fib(10))
print("fib(15) = " .. fib(15))

-- Mutual recursion
local is_even, is_odd

is_even = function(n)
    if n == 0 then return true end
    return is_odd(n - 1)
end

is_odd = function(n)
    if n == 0 then return false end
    return is_even(n - 1)
end

print("is_even(10) = " .. tostring(is_even(10)))
print("is_odd(7) = " .. tostring(is_odd(7)))
print("")

-- ============================================================================
-- Part 4: Higher-Order Functions
-- ============================================================================
print("--- Part 4: Higher-Order Functions ---")

-- Map function
local function map(t, fn)
    local result = {}
    for i = 1, #t do
        result[i] = fn(t[i])
    end
    return result
end

local numbers = {1, 2, 3, 4, 5}
local squared = map(numbers, function(x) return x * x end)
print("Original: " .. table.concat(numbers, ", "))
print("Squared:  " .. table.concat(squared, ", "))

-- Filter function
local function filter(t, predicate)
    local result = {}
    for i = 1, #t do
        if predicate(t[i]) then
            table.insert(result, t[i])
        end
    end
    return result
end

local evens = filter(numbers, function(x) return x % 2 == 0 end)
print("Evens:    " .. table.concat(evens, ", "))

-- Reduce/fold function
local function reduce(t, fn, initial)
    local acc = initial
    for i = 1, #t do
        acc = fn(acc, t[i])
    end
    return acc
end

local product = reduce(numbers, function(a, b) return a * b end, 1)
print("Product:  " .. product)

-- Compose functions
local function compose(f, g)
    return function(x)
        return f(g(x))
    end
end

local double = function(x) return x * 2 end
local add_one = function(x) return x + 1 end
local double_then_add = compose(add_one, double)
local add_then_double = compose(double, add_one)

print("double_then_add(5) = " .. double_then_add(5))
print("add_then_double(5) = " .. add_then_double(5))
print("")

-- ============================================================================
-- Part 5: Function as Data / Callbacks
-- ============================================================================
print("--- Part 5: Function as Data ---")

-- Operation dispatch table
local operations = {
    add = function(a, b) return a + b end,
    sub = function(a, b) return a - b end,
    mul = function(a, b) return a * b end,
    div = function(a, b) return a / b end,
}

local function calculate(op, a, b)
    local fn = operations[op]
    if fn then
        return fn(a, b)
    end
    return nil
end

print("calculate('add', 10, 3) = " .. calculate("add", 10, 3))
print("calculate('mul', 10, 3) = " .. calculate("mul", 10, 3))

-- Currying example
local function curry_add(a)
    return function(b)
        return a + b
    end
end

local add5 = curry_add(5)
local add10 = curry_add(10)
print("add5(3) = " .. add5(3))
print("add10(3) = " .. add10(3))

-- Partial application
local function partial(fn, first_arg)
    return function(second_arg)
        return fn(first_arg, second_arg)
    end
end

local function multiply(a, b)
    return a * b
end

local double = partial(multiply, 2)
local triple = partial(multiply, 3)
print("double(7) = " .. double(7))
print("triple(7) = " .. triple(7))

-- Memoization (caching function results)
local function memoize(fn)
    local cache = {}
    return function(n)
        if cache[n] == nil then
            cache[n] = fn(n)
        end
        return cache[n]
    end
end

local call_count = 0
local slow_square = function(n)
    call_count = call_count + 1
    return n * n
end
local fast_square = memoize(slow_square)

print("Memoized: " .. fast_square(5) .. ", " .. fast_square(5) .. ", " .. fast_square(3))
print("Call count (should be 2): " .. call_count)
print("")

-- ============================================================================
-- Part 6: Stress Test (Many Objects for GC)
-- ============================================================================
print("--- Part 6: Object Creation Stress Test ---")

-- Create many closures to stress GC
local function create_closures(n)
    local closures = {}
    for i = 1, n do
        local val = i
        closures[i] = function()
            return val * val
        end
    end
    return closures
end

local many_closures = create_closures(100)
local sum = 0
for i = 1, #many_closures do
    sum = sum + many_closures[i]()
end
print("Sum of 100 closure results: " .. sum)

-- Create many tables with functions
local function create_objects(n)
    local objects = {}
    for i = 1, n do
        local id = i
        objects[i] = {
            id = id,
            name = "obj" .. id,
            getValue = function()
                return id * 10
            end
        }
    end
    return objects
end

local many_objects = create_objects(50)
local total = 0
for i = 1, #many_objects do
    total = total + many_objects[i].getValue()
end
print("Sum of 50 object values: " .. total)

-- Recursive structure creation (trees)
local function create_tree(depth)
    if depth <= 0 then
        return { value = 1 }
    end
    return {
        value = depth,
        left = create_tree(depth - 1),
        right = create_tree(depth - 1)
    }
end

local function sum_tree(node)
    if node.left == nil then
        return node.value
    end
    return node.value + sum_tree(node.left) + sum_tree(node.right)
end

local tree = create_tree(5)
print("Tree depth 5 sum: " .. sum_tree(tree))

print("")

print("=== Demo Complete ===")
