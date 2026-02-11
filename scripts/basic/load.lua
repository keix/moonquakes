-- Test load function

-- Basic: load and execute simple chunk
local fn = load("return 42")
print("type: " .. type(fn))
-- expect: type: function

local result = fn()
print("result: " .. tostring(result))
-- expect: result: 42

-- Arithmetic expression
local add_fn = load("return 1 + 2 + 3")
print("add: " .. tostring(add_fn()))
-- expect: add: 6

-- Multiple return values
local multi_fn = load("return 10, 20, 30")
local a, b, c = multi_fn()
print("multi: " .. a .. ", " .. b .. ", " .. c)
-- expect: multi: 10, 20, 30

-- String return
local str_fn = load("return 'hello'")
print("string: " .. str_fn())
-- expect: string: hello

-- Boolean return
local bool_fn = load("return true")
print("bool: " .. tostring(bool_fn()))
-- expect: bool: true

-- Nil return
local nil_fn = load("return nil")
print("nil: " .. tostring(nil_fn()))
-- expect: nil: nil

-- Empty chunk (returns nothing)
local empty_fn = load("")
local empty_result = empty_fn()
print("empty: " .. tostring(empty_result))
-- expect: empty: nil

-- Load with syntax error returns nil and error message
local bad_fn, err = load("this is not valid lua")
print("bad fn: " .. tostring(bad_fn))
-- expect: bad fn: nil

-- Load function that creates local variables
local local_fn = load("local x = 5 return x * 2")
print("local: " .. tostring(local_fn()))
-- expect: local: 10

-- Load function with table
local table_fn = load("return {1, 2, 3}")
local t = table_fn()
print("table len: " .. #t)
-- expect: table len: 3

-- Load function called multiple times
local counter_fn = load("return 100")
print("call1: " .. tostring(counter_fn()))
-- expect: call1: 100
print("call2: " .. tostring(counter_fn()))
-- expect: call2: 100

-- Nested function definition
local nested_fn = load("local function f(x) return x + 1 end return f(10)")
print("nested: " .. tostring(nested_fn()))
-- expect: nested: 11

print("load tests passed")
-- expect: load tests passed
