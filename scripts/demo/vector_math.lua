-- Vector Math Library Demo
-- Demonstrates: tables, methods, closures, recursion, control flow

-- Vector constructor
local function Vec2(x, y)
    return {
        x = x,
        y = y,

        add = function(self, other)
            return Vec2(self.x + other.x, self.y + other.y)
        end,

        scale = function(self, s)
            return Vec2(self.x * s, self.y * s)
        end,

        dot = function(self, other)
            return self.x * other.x + self.y * other.y
        end,

        lengthSq = function(self)
            return self:dot(self)
        end,

        toString = function(self)
            return "(" .. tostring(self.x) .. ", " .. tostring(self.y) .. ")"
        end
    }
end

-- Create some vectors
local a = Vec2(3, 4)
local b = Vec2(1, 2)

-- Test operations
local sum = a:add(b)
local scaled = a:scale(2)
local dotProduct = a:dot(b)
local lenSq = a:lengthSq()

print "Vector operations:"
print("a = " .. a:toString())
print("b = " .. b:toString())
print("a + b = " .. sum:toString())
print("a * 2 = " .. scaled:toString())
print("a . b = " .. tostring(dotProduct))
print("len(a)^2 = " .. tostring(lenSq))

-- Simple counter using closures
local function createCounter(initial)
    local count = initial

    return {
        inc = function(self)
            count = count + 1
        end,

        get = function(self)
            return count
        end,

        reset = function(self)
            count = initial
        end
    }
end

print ""
print "Counter demo:"
local counter = createCounter(10)
print("Initial: " .. tostring(counter:get()))
counter:inc()
counter:inc()
counter:inc()
print("After 3 inc: " .. tostring(counter:get()))
counter:reset()
print("After reset: " .. tostring(counter:get()))

-- Prime number checker
local function isPrime(n)
    if n < 2 then
        return false
    end
    if n == 2 then
        return true
    end
    if n % 2 == 0 then
        return false
    end
    local i = 3
    while i * i <= n do
        if n % i == 0 then
            return false
        end
        i = i + 2
    end
    return true
end

-- Count primes up to n
local function countPrimes(n)
    local count = 0
    local i = 2
    while i <= n do
        if isPrime(i) then
            count = count + 1
        end
        i = i + 1
    end
    return count
end

print ""
print "Prime numbers:"
local primeCount = countPrimes(100)
print("Primes up to 100: " .. tostring(primeCount))

-- Bitwise operations demo
print ""
print "Bitwise operations:"
local x = 0xFF
local y = 0x0F
print("x = " .. tostring(x) .. " (0xFF)")
print("y = " .. tostring(y) .. " (0x0F)")
print("x & y = " .. tostring(x & y))
print("x | y = " .. tostring(x | y))
print("x << 4 = " .. tostring(x << 4))
print("x >> 4 = " .. tostring(x >> 4))

-- Recursive factorial
local function factorial(n)
    if n <= 1 then
        return 1
    end
    return n * factorial(n - 1)
end

print ""
print "Factorial:"
print("5! = " .. tostring(factorial(5)))
print("10! = " .. tostring(factorial(10)))

-- Numeric for loop
print ""
print "For loop sum 1 to 10:"
local sum2 = 0
for i = 1, 10 do
    sum2 = sum2 + i
end
print("Sum = " .. tostring(sum2))

-- Return summary
return primeCount + factorial(5) + counter:get()
