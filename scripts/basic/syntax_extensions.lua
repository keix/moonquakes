-- Test syntax extensions added for Lua 5.4 compatibility

-- 1. Empty statements (;)
;;;
do ;;; end
; do ; end;

-- 2. function t.field() syntax
local obj = {}
function obj.greet(name)
    return "Hello, " .. name
end
assert(obj.greet("World") == "Hello, World", "function t.field() failed")

-- 3. function t:method() syntax
function obj:getValue()
    return self.value or 0
end
obj.value = 42
assert(obj:getValue() == 42, "function t:method() failed")

-- 4. Nested field function: function t.a.b()
local t = { inner = {} }
function t.inner.compute(x)
    return x * 2
end
assert(t.inner.compute(5) == 10, "function t.a.b() failed")

-- 5. Multi-target indexed assignment
local a, b = {}, {}
a[1], b[2], a[3] = 10, 20, 30
assert(a[1] == 10, "multi-target a[1] failed")
assert(b[2] == 20, "multi-target b[2] failed")
assert(a[3] == 30, "multi-target a[3] failed")

-- 6. goto / ::label:: (forward jump)
goto forward
assert(false, "should be skipped")
::forward::

-- 7. goto / ::label:: (backward jump for loop)
local counter = 0
::loop_start::
counter = counter + 1
if counter < 3 then goto loop_start end
assert(counter == 3, "goto backward loop failed")

-- 8. Unary operators in power expressions
assert(2^-2 == 0.25, "2^-2 failed")
assert(2^- -2 == 4, "2^- -2 failed")
assert(-2^2 == -4, "-2^2 failed")
assert((-2)^2 == 4, "(-2)^2 failed")

-- 9. Semicolons after return
local function test_semi()
    if true then return 1; end;
    return 2
end
assert(test_semi() == 1, "semicolon after return failed")

-- 10. Bare return with semicolon
local function bare()
    return;
end
assert(bare() == nil, "bare return; failed")

-- 11. function keyword in nested do-end blocks
do
    local x = 0
    function increment()
        x = x + 1
        return x
    end
    assert(increment() == 1, "function in do block failed")
    assert(increment() == 2, "function in do block failed")
end

-- 12. function f() respects local shadowing
local function shadow(n) return n * 2 end
assert(shadow(5) == 10, "original shadow failed")
do
    function shadow(n) return n * 3 end
end
assert(shadow(5) == 15, "reassigned shadow failed")

print("syntax_extensions: PASSED")
