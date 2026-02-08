-- Statistics Demo
-- Demonstrates table, math, and core language features

print("=== Moonquakes Statistics Demo ===")
print("")

-- Sample data: exam scores
local scores = {78, 92, 65, 88, 73, 95, 81, 67, 89, 74, 86, 91, 70, 83, 77}

print("Original scores:")
print("  " .. table.concat(scores, ", "))
print("")

-- Sort the scores
table.sort(scores)
print("Sorted scores:")
print("  " .. table.concat(scores, ", "))
print("")

-- Calculate statistics
local function sum(t)
    local total = 0
    for i = 1, #t do
        total = total + t[i]
    end
    return total
end

local function mean(t)
    return sum(t) / #t
end

local function median(t)
    local n = #t
    if n % 2 == 1 then
        return t[math.floor(n / 2) + 1]
    else
        local mid = n / 2
        return (t[mid] + t[mid + 1]) / 2
    end
end

local function min_max(t)
    -- Since sorted, first and last
    return t[1], t[#t]
end

local function variance(t)
    local m = mean(t)
    local sum_sq = 0
    for i = 1, #t do
        local diff = t[i] - m
        sum_sq = sum_sq + diff * diff
    end
    return sum_sq / #t
end

local function std_dev(t)
    return math.sqrt(variance(t))
end

-- Calculate and display statistics
local total = sum(scores)
local avg = mean(scores)
local med = median(scores)
local min_val, max_val = min_max(scores)
local var = variance(scores)
local sd = std_dev(scores)

print("Statistics:")
print("  Count:    " .. #scores)
print("  Sum:      " .. total)
print("  Mean:     " .. string.format("%.2f", avg))
print("  Median:   " .. med)
print("  Min:      " .. min_val)
print("  Max:      " .. max_val)
print("  Range:    " .. (max_val - min_val))
print("  Variance: " .. string.format("%.2f", var))
print("  Std Dev:  " .. string.format("%.2f", sd))
print("")

-- Grade distribution
local function count_grades(t)
    local grades = {A = 0, B = 0, C = 0, D = 0, F = 0}
    for i = 1, #t do
        local score = t[i]
        if score >= 90 then
            grades.A = grades.A + 1
        elseif score >= 80 then
            grades.B = grades.B + 1
        elseif score >= 70 then
            grades.C = grades.C + 1
        elseif score >= 60 then
            grades.D = grades.D + 1
        else
            grades.F = grades.F + 1
        end
    end
    return grades
end

local grades = count_grades(scores)
print("Grade Distribution:")
print("  A (90-100): " .. grades.A)
print("  B (80-89):  " .. grades.B)
print("  C (70-79):  " .. grades.C)
print("  D (60-69):  " .. grades.D)
print("  F (0-59):   " .. grades.F)
print("")

-- Histogram (simple ASCII)
local function histogram(t, bins)
    local min_v, max_v = min_max(t)
    local range = max_v - min_v
    local bin_size = range / bins
    local counts = {}

    for i = 1, bins do
        counts[i] = 0
    end

    for i = 1, #t do
        local val = t[i]
        local bin = math.floor((val - min_v) / bin_size) + 1
        if bin > bins then bin = bins end
        counts[bin] = counts[bin] + 1
    end

    return counts, min_v, bin_size
end

local hist, hist_min, bin_size = histogram(scores, 5)
print("Score Histogram:")
for i = 1, 5 do
    local low = math.floor(hist_min + (i - 1) * bin_size)
    local high = math.floor(hist_min + i * bin_size - 1)
    local bar = ""
    for j = 1, hist[i] do
        bar = bar .. "*"
    end
    print(string.format("  %2d-%2d: %s (%d)", low, high, bar, hist[i]))
end
print("")

-- Demonstrate table.pack and table.unpack
print("=== Table Pack/Unpack Demo ===")
local packed = table.pack(10, 20, 30, 40, 50)
print("Packed table with n=" .. packed.n)

local a, b, c = table.unpack(packed, 1, 3)
print("Unpacked first 3: " .. a .. ", " .. b .. ", " .. c)
print("")

-- Demonstrate table.move
print("=== Table Move Demo ===")
local src = {1, 2, 3, 4, 5}
local dst = {10, 20, 30}
print("Source: " .. table.concat(src, ", "))
print("Dest before: " .. table.concat(dst, ", "))
table.move(src, 2, 4, 4, dst)
print("After move(src, 2, 4, 4, dst): " .. table.concat(dst, ", "))
print("")

-- Demonstrate table.insert and table.remove (stack)
print("=== Stack Demo ===")
local stack = {}
print("Pushing to stack...")
for i = 1, 5 do
    table.insert(stack, "item" .. i)
    print("  Push: item" .. i .. " -> [" .. table.concat(stack, ", ") .. "]")
end

print("Popping from stack...")
while #stack > 0 do
    local item = table.remove(stack)
    local remaining = #stack > 0 and table.concat(stack, ", ") or "(empty)"
    print("  Pop: " .. item .. " -> [" .. remaining .. "]")
end
print("")

-- Prime number finder using math
print("=== Prime Numbers (using math.sqrt) ===")
local function is_prime(n)
    if n < 2 then return false end
    if n == 2 then return true end
    if n % 2 == 0 then return false end

    local limit = math.floor(math.sqrt(n))
    for i = 3, limit, 2 do
        if n % i == 0 then return false end
    end
    return true
end

local primes = {}
for n = 2, 50 do
    if is_prime(n) then
        table.insert(primes, n)
    end
end
print("Primes up to 50: " .. table.concat(primes, ", "))
print("Count: " .. #primes)
print("")

-- Fibonacci sequence
print("=== Fibonacci Sequence ===")
local function fibonacci(n)
    local fib = {1, 1}
    for i = 3, n do
        fib[i] = fib[i-1] + fib[i-2]
    end
    return fib
end

local fib = fibonacci(15)
print("First 15 Fibonacci numbers:")
print("  " .. table.concat(fib, ", "))
print("Sum: " .. sum(fib))
print("")

-- Trigonometry demo
print("=== Trigonometry Demo ===")
local angles = {0, 30, 45, 60, 90}
print("Angle | sin      | cos      | tan")
print("------+----------+----------+----------")
for i = 1, #angles do
    local deg = angles[i]
    local rad = deg * math.pi / 180
    local sin_v = math.sin(rad)
    local cos_v = math.cos(rad)
    local tan_v
    if deg == 90 then
        tan_v = "inf"
    else
        tan_v = string.format("%8.4f", math.tan(rad))
    end
    print(string.format("%5d | %8.4f | %8.4f | %s", deg, sin_v, cos_v, tan_v))
end
print("")

print("=== Demo Complete ===")
