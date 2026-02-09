-- Sorting Algorithms Demo
-- Demonstrates table manipulation and algorithms

-- Generate random-ish array
local function make_array(n, seed)
    local arr = {}
    local x = seed
    for i = 1, n do
        x = (x * 1103515245 + 12345) % 2147483648
        arr[i] = x % 1000
    end
    return arr
end

-- Copy array
local function copy_array(arr)
    local result = {}
    for i, v in ipairs(arr) do
        result[i] = v
    end
    return result
end

-- Check if sorted
local function is_sorted(arr)
    for i = 1, #arr - 1 do
        if arr[i] > arr[i + 1] then
            return false
        end
    end
    return true
end

-- Bubble Sort
local function bubble_sort(arr)
    local n = #arr
    for i = 1, n do
        for j = 1, n - i do
            if arr[j] > arr[j + 1] then
                local tmp = arr[j]
                arr[j] = arr[j + 1]
                arr[j + 1] = tmp
            end
        end
    end
    return arr
end

-- Insertion Sort
local function insertion_sort(arr)
    local n = #arr
    for i = 2, n do
        local key = arr[i]
        local j = i - 1
        while j > 0 and arr[j] > key do
            arr[j + 1] = arr[j]
            j = j - 1
        end
        arr[j + 1] = key
    end
    return arr
end

-- Selection Sort
local function selection_sort(arr)
    local n = #arr
    for i = 1, n - 1 do
        local min_idx = i
        for j = i + 1, n do
            if arr[j] < arr[min_idx] then
                min_idx = j
            end
        end
        if min_idx ~= i then
            local tmp = arr[i]
            arr[i] = arr[min_idx]
            arr[min_idx] = tmp
        end
    end
    return arr
end

-- Print first N elements
local function print_array(arr, n)
    local parts = {}
    local count = 0
    for i = 1, n do
        if arr[i] then
            count = count + 1
            parts[count] = arr[i]
        end
    end
    local str = "["
    for i, v in ipairs(parts) do
        if i > 1 then str = str .. ", " end
        str = str .. v
    end
    str = str .. "]"
    print(str)
end

-- Main
print("=== Sorting Algorithms Demo ===")
print("")

local size = 20
local original = make_array(size, 42)

print("Original array (first 10):")
print_array(original, 10)
print("")

-- Test Bubble Sort
local arr1 = copy_array(original)
bubble_sort(arr1)
print("Bubble Sort result (first 10):")
print_array(arr1, 10)
assert(is_sorted(arr1), "Bubble sort failed!")
print("Verified: sorted correctly")
print("")

-- Test Insertion Sort
local arr2 = copy_array(original)
insertion_sort(arr2)
print("Insertion Sort result (first 10):")
print_array(arr2, 10)
assert(is_sorted(arr2), "Insertion sort failed!")
print("Verified: sorted correctly")
print("")

-- Test Selection Sort
local arr3 = copy_array(original)
selection_sort(arr3)
print("Selection Sort result (first 10):")
print_array(arr3, 10)
assert(is_sorted(arr3), "Selection sort failed!")
print("Verified: sorted correctly")

print("")
print("All sorting algorithms work correctly!")
