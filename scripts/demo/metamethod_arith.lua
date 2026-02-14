-- Arithmetic Metamethod Tests
-- Testing __add, __sub, __mul, __div, __mod, __pow, __unm, __concat

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
-- Part 1: Vector2D with arithmetic metamethods
-- ============================================================================
print("=== Part 1: Vector2D ===")

local Vec2 = {}
Vec2.__index = Vec2

function Vec2.new(x, y)
  local v = { x = x, y = y }
  setmetatable(v, Vec2)
  return v
end

function Vec2.__add(a, b)
  -- Test: are a and b correct types?
  if type(a) ~= "table" or type(b) ~= "table" then
    print("  ERROR: __add received wrong types: " .. type(a) .. ", " .. type(b))
    return nil
  end
  return Vec2.new(a.x + b.x, a.y + b.y)
end

function Vec2.__sub(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    print("  ERROR: __sub received wrong types")
    return nil
  end
  return Vec2.new(a.x - b.x, a.y - b.y)
end

function Vec2.__mul(a, b)
  -- Handle both Vec2 * number and number * Vec2
  if type(a) == "table" and type(b) == "number" then
    return Vec2.new(a.x * b, a.y * b)
  elseif type(a) == "number" and type(b) == "table" then
    return Vec2.new(a * b.x, a * b.y)
  elseif type(a) == "table" and type(b) == "table" then
    -- Dot product returns number
    return a.x * b.x + a.y * b.y
  else
    print("  ERROR: __mul received wrong types: " .. type(a) .. ", " .. type(b))
    return nil
  end
end

function Vec2.__div(a, b)
  if type(a) == "table" and type(b) == "number" then
    return Vec2.new(a.x / b, a.y / b)
  else
    print("  ERROR: __div received wrong types")
    return nil
  end
end

function Vec2.__unm(a)
  if type(a) ~= "table" then
    print("  ERROR: __unm received wrong type: " .. type(a))
    return nil
  end
  return Vec2.new(-a.x, -a.y)
end

function Vec2.__eq(a, b)
  return a.x == b.x and a.y == b.y
end

function Vec2.__tostring(v)
  return "Vec2(" .. v.x .. ", " .. v.y .. ")"
end

function Vec2:length()
  return (self.x * self.x + self.y * self.y) ^ 0.5
end

-- Create test vectors
local v1 = Vec2.new(3, 4)
local v2 = Vec2.new(1, 2)

test("Vec2 creation", v1.x == 3 and v1.y == 4)
test("Vec2 tostring", tostring(v1) == "Vec2(3, 4)")

-- Test __add
print("\n-- Testing __add --")
local v3 = v1 + v2
test("__add result type", type(v3) == "table")
test("__add x component", v3.x == 4)
test("__add y component", v3.y == 6)

-- Test __sub
print("\n-- Testing __sub --")
local v4 = v1 - v2
test("__sub result type", type(v4) == "table")
test("__sub x component", v4.x == 2)
test("__sub y component", v4.y == 2)

-- Test __mul (vector * scalar)
print("\n-- Testing __mul --")
local v5 = v1 * 2
test("__mul vec*scalar type", type(v5) == "table")
test("__mul vec*scalar x", v5.x == 6)
test("__mul vec*scalar y", v5.y == 8)

-- Test __mul (scalar * vector)
local v6 = 3 * v2
test("__mul scalar*vec type", type(v6) == "table")
test("__mul scalar*vec x", v6.x == 3)
test("__mul scalar*vec y", v6.y == 6)

-- Test __mul (dot product)
local dot = v1 * v2
test("__mul dot product", dot == 11)  -- 3*1 + 4*2 = 11

-- Test __div
print("\n-- Testing __div --")
local v7 = Vec2.new(6, 8) / 2
test("__div type", type(v7) == "table")
test("__div x", v7.x == 3)
test("__div y", v7.y == 4)

-- Test __unm (unary minus)
print("\n-- Testing __unm --")
local v8 = -v1
test("__unm type", type(v8) == "table")
test("__unm x", v8.x == -3)
test("__unm y", v8.y == -4)

-- Test __eq
print("\n-- Testing __eq --")
local v9 = Vec2.new(3, 4)
test("__eq same values", v1 == v9)
test("__eq different values", not (v1 == v2))

-- Test method call on result (checks self is correct)
print("\n-- Testing method on result --")
local v10 = Vec2.new(3, 4)
test("length method", v10:length() == 5)

local v11 = v1 + Vec2.new(0, 0)
test("length on add result", v11:length() == 5)

-- ============================================================================
-- Part 2: Complex Numbers
-- ============================================================================
print("\n=== Part 2: Complex Numbers ===")

local Complex = {}
Complex.__index = Complex

function Complex.new(real, imag)
  local c = { real = real, imag = imag or 0 }
  setmetatable(c, Complex)
  return c
end

function Complex.__add(a, b)
  local ar = type(a) == "table" and a.real or a
  local ai = type(a) == "table" and a.imag or 0
  local br = type(b) == "table" and b.real or b
  local bi = type(b) == "table" and b.imag or 0
  return Complex.new(ar + br, ai + bi)
end

function Complex.__sub(a, b)
  local ar = type(a) == "table" and a.real or a
  local ai = type(a) == "table" and a.imag or 0
  local br = type(b) == "table" and b.real or b
  local bi = type(b) == "table" and b.imag or 0
  return Complex.new(ar - br, ai - bi)
end

function Complex.__mul(a, b)
  local ar = type(a) == "table" and a.real or a
  local ai = type(a) == "table" and a.imag or 0
  local br = type(b) == "table" and b.real or b
  local bi = type(b) == "table" and b.imag or 0
  -- (ar + ai*i) * (br + bi*i) = ar*br - ai*bi + (ar*bi + ai*br)*i
  return Complex.new(ar * br - ai * bi, ar * bi + ai * br)
end

function Complex.__unm(a)
  return Complex.new(-a.real, -a.imag)
end

function Complex.__eq(a, b)
  return a.real == b.real and a.imag == b.imag
end

function Complex.__tostring(c)
  if c.imag >= 0 then
    return c.real .. "+" .. c.imag .. "i"
  else
    return c.real .. c.imag .. "i"
  end
end

function Complex:magnitude()
  return (self.real * self.real + self.imag * self.imag) ^ 0.5
end

function Complex:conjugate()
  return Complex.new(self.real, -self.imag)
end

local c1 = Complex.new(3, 4)
local c2 = Complex.new(1, 2)

test("Complex creation", c1.real == 3 and c1.imag == 4)
test("Complex tostring", tostring(c1) == "3+4i")

-- Complex addition
local c3 = c1 + c2
test("Complex add real", c3.real == 4)
test("Complex add imag", c3.imag == 6)

-- Complex subtraction
local c4 = c1 - c2
test("Complex sub real", c4.real == 2)
test("Complex sub imag", c4.imag == 2)

-- Complex multiplication
-- (3+4i) * (1+2i) = 3 + 6i + 4i + 8i^2 = 3 + 10i - 8 = -5 + 10i
local c5 = c1 * c2
test("Complex mul real", c5.real == -5)
test("Complex mul imag", c5.imag == 10)

-- Complex with scalar
local c6 = c1 + 5
test("Complex + scalar", c6.real == 8 and c6.imag == 4)

local c7 = 2 * c1
test("scalar * Complex", c7.real == 6 and c7.imag == 8)

-- Unary minus
local c8 = -c1
test("Complex unm", c8.real == -3 and c8.imag == -4)

-- Method on Complex
test("Complex magnitude", c1:magnitude() == 5)

local c9 = c1:conjugate()
test("Complex conjugate", c9.real == 3 and c9.imag == -4)

-- ============================================================================
-- Part 3: Chained Operations
-- ============================================================================
print("\n=== Part 3: Chained Operations ===")

local a = Vec2.new(1, 1)
local b = Vec2.new(2, 2)
local c = Vec2.new(3, 3)

-- (a + b) + c
local r1 = (a + b) + c
test("Chained add", r1.x == 6 and r1.y == 6)

-- a + b + c (left associative)
local r2 = a + b + c
test("Triple add", r2.x == 6 and r2.y == 6)

-- Mixed operations
local r3 = (a + b) * 2
test("Add then mul", r3.x == 6 and r3.y == 6)

local r4 = a * 2 + b
test("Mul then add", r4.x == 4 and r4.y == 4)

-- Negation chain
local r5 = -(-a)
test("Double negation", r5.x == 1 and r5.y == 1)

-- ============================================================================
-- Part 4: __pow and __mod
-- ============================================================================
print("\n=== Part 4: __pow and __mod ===")

local Num = {}
Num.__index = Num

function Num.new(val)
  return setmetatable({ val = val }, Num)
end

function Num.__pow(a, b)
  local av = type(a) == "table" and a.val or a
  local bv = type(b) == "table" and b.val or b
  return Num.new(av ^ bv)
end

function Num.__mod(a, b)
  local av = type(a) == "table" and a.val or a
  local bv = type(b) == "table" and b.val or b
  return Num.new(av % bv)
end

local n1 = Num.new(2)
local n2 = Num.new(3)

local p = n1 ^ n2
test("__pow", p.val == 8)

local n3 = Num.new(10)
local n4 = Num.new(3)
local m = n3 % n4
test("__mod", m.val == 1)

-- ============================================================================
-- Part 5: __concat
-- ============================================================================
print("\n=== Part 5: __concat ===")

local Str = {}
Str.__index = Str

function Str.new(s)
  return setmetatable({ s = s }, Str)
end

function Str.__concat(a, b)
  local as = type(a) == "table" and a.s or tostring(a)
  local bs = type(b) == "table" and b.s or tostring(b)
  return Str.new(as .. bs)
end

function Str.__tostring(self)
  return self.s
end

local s1 = Str.new("Hello")
local s2 = Str.new("World")

local s3 = s1 .. s2
test("__concat", s3.s == "HelloWorld")

-- Note: chained concat with more than 2 operands needs explicit pairing
-- because CONCAT instruction currently only handles metamethod for 2 operands
local s4_temp1 = s1 .. ", "
local s4_temp2 = s4_temp1 .. s2
local s4 = s4_temp2 .. "!"
test("__concat chain", s4.s == "Hello, World!")

-- ============================================================================
-- Part 6: Method calls after metamethod operations
-- ============================================================================
print("\n=== Part 6: Method on metamethod result ===")

function Vec2:normalize()
  local len = self:length()
  if len > 0 then
    return Vec2.new(self.x / len, self.y / len)
  end
  return Vec2.new(0, 0)
end

function Vec2:dot(other)
  return self.x * other.x + self.y * other.y
end

local va = Vec2.new(3, 0)
local vb = Vec2.new(0, 4)

-- Add then call method
local vc = va + vb
test("Method after add - type", type(vc) == "table")
test("Method after add - length", vc:length() == 5)

-- Normalize the result of addition
-- Note: (va + vb):normalize() syntax not yet supported, use temp variable
local vd_temp = va + vb
local vd = vd_temp:normalize()
test("Chained method x", vd.x == 0.6)
test("Chained method y", vd.y == 0.8)

-- Method call on multiplication result
local ve_temp = va * 2
local ve = ve_temp:normalize()
test("Method on mul result", ve.x == 1 and ve.y == 0)

-- ============================================================================
-- Part 7: Edge cases
-- ============================================================================
print("\n=== Part 7: Edge Cases ===")

-- Zero vector
local zero = Vec2.new(0, 0)
local vzero = zero + zero
test("Zero + Zero", vzero.x == 0 and vzero.y == 0)

-- Negative values
local vneg = Vec2.new(-5, -10)
local vpos = -vneg
test("Negate negative", vpos.x == 5 and vpos.y == 10)

-- Large values
local vlarge = Vec2.new(1000000, 2000000)
local vdouble = vlarge * 2
test("Large values", vdouble.x == 2000000 and vdouble.y == 4000000)

-- Float precision
local vfloat = Vec2.new(0.1, 0.2)
local vfloat2 = vfloat + Vec2.new(0.1, 0.1)
test("Float add", vfloat2.x > 0.19 and vfloat2.x < 0.21)

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
