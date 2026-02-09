-- Prime Numbers Demo
-- Demonstrates mathematical algorithms

-- Check if n is prime
local function is_prime(n)
    if n < 2 then return false end
    if n == 2 then return true end
    if n % 2 == 0 then return false end

    local i = 3
    while i * i <= n do
        if n % i == 0 then
            return false
        end
        i = i + 2
    end
    return true
end

-- Sieve of Eratosthenes
local function sieve(limit)
    local is_prime_arr = {}
    for i = 2, limit do
        is_prime_arr[i] = true
    end

    local i = 2
    while i * i <= limit do
        if is_prime_arr[i] then
            local j = i * i
            while j <= limit do
                is_prime_arr[j] = false
                j = j + i
            end
        end
        i = i + 1
    end

    local primes = {}
    local count = 0
    for i = 2, limit do
        if is_prime_arr[i] then
            count = count + 1
            primes[count] = i
        end
    end
    return primes
end

-- Prime factorization
local function factorize(n)
    local factors = {}
    local count = 0
    local d = 2

    while d * d <= n do
        while n % d == 0 do
            count = count + 1
            factors[count] = d
            n = n / d
        end
        d = d + 1
    end

    if n > 1 then
        count = count + 1
        factors[count] = n
    end

    return factors
end

-- Format factors as string
local function format_factors(factors)
    local str = ""
    for i, f in ipairs(factors) do
        if i > 1 then str = str .. " x " end
        str = str .. f
    end
    return str
end

-- Main
print("=== Prime Numbers Demo ===")
print("")

-- Find primes up to 100
print("Primes up to 100 (Sieve of Eratosthenes):")
local primes = sieve(100)
local line = ""
for i, p in ipairs(primes) do
    if string.len(line) > 50 then
        print(line)
        line = ""
    end
    if string.len(line) > 0 then line = line .. " " end
    line = line .. p
end
if string.len(line) > 0 then print(line) end
print("Total: " .. #primes .. " primes")
print("")

-- Verify with is_prime
print("Verification with is_prime():")
local verified = 0
for i, p in ipairs(primes) do
    if is_prime(p) then
        verified = verified + 1
    end
end
print("All " .. verified .. " primes verified!")
print("")

-- Prime factorization
print("Prime factorization:")
local test_nums = {12, 60, 97, 100, 360, 1024}
for i, n in ipairs(test_nums) do
    local factors = factorize(n)
    print(n .. " = " .. format_factors(factors))
end
print("")

-- Find twin primes
print("Twin primes up to 100:")
local twins = {}
local twin_count = 0
for i = 1, #primes - 1 do
    if primes[i + 1] - primes[i] == 2 then
        twin_count = twin_count + 1
        twins[twin_count] = "(" .. primes[i] .. ", " .. primes[i + 1] .. ")"
    end
end
local twin_str = ""
for i, t in ipairs(twins) do
    if i > 1 then twin_str = twin_str .. " " end
    twin_str = twin_str .. t
end
print(twin_str)

print("")
print("Prime demo complete!")
