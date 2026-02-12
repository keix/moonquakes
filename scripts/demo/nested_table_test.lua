-- Test nested table access and assignment
print("=== Nested Table Test ===")

-- Basic nested access
local t = {}
t[1] = {}
t[1][1] = "hello"
print("t[1][1] = " .. t[1][1])
-- expect: t[1][1] = hello

-- Multiple levels
local m = {}
m.a = {}
m.a.b = {}
m.a.b.c = 42
print("m.a.b.c = " .. m.a.b.c)
-- expect: m.a.b.c = 42

-- Mixed access
local x = {}
x[1] = {}
x[1].name = "first"
x[1].value = 100
print("x[1].name = " .. x[1].name)
print("x[1].value = " .. x[1].value)
-- expect: x[1].name = first
-- expect: x[1].value = 100

-- 2D array
local matrix = {}
for i = 1, 3 do
    matrix[i] = {}
    for j = 1, 3 do
        matrix[i][j] = i * 10 + j
    end
end

print("Matrix:")
for i = 1, 3 do
    local row = ""
    for j = 1, 3 do
        row = row .. matrix[i][j] .. " "
    end
    print(row)
end
-- expect: Matrix:
-- expect: 11 12 13
-- expect: 21 22 23
-- expect: 31 32 33

-- Nested table with method-like access
local obj = {
    data = {
        items = {}
    }
}
obj.data.items[1] = "apple"
obj.data.items[2] = "banana"
print("Items: " .. obj.data.items[1] .. ", " .. obj.data.items[2])
-- expect: Items: apple, banana

print("=== Nested Table Test PASSED ===")
