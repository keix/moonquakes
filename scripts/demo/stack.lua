-- Stack Data Structure Demo
-- Demonstrates closures, tables, and OOP-like patterns

local function create_stack()
    local items = {}
    local size = 0

    return {
        push = function(value)
            size = size + 1
            items[size] = value
        end,
        pop = function()
            if size == 0 then
                return nil
            end
            local value = items[size]
            items[size] = nil
            size = size - 1
            return value
        end,
        peek = function()
            if size == 0 then
                return nil
            end
            return items[size]
        end,
        is_empty = function()
            return size == 0
        end,
        get_size = function()
            return size
        end
    }
end

-- Balanced parentheses checker using stack
local function check_balanced(str)
    local stack = create_stack()
    local pairs = {
        ["("] = ")",
        ["["] = "]",
        ["{"] = "}"
    }
    local closing = {
        [")"] = true,
        ["]"] = true,
        ["}"] = true
    }

    for i = 1, string.len(str) do
        local c = string.sub(str, i, i)
        if pairs[c] then
            stack.push(c)
        elseif closing[c] then
            if stack.is_empty() then
                return false
            end
            local top = stack.pop()
            if pairs[top] ~= c then
                return false
            end
        end
    end

    return stack.is_empty()
end

-- Main
print("=== Stack Data Structure Demo ===")
print("")

-- Basic stack operations
print("Basic stack operations:")
local s = create_stack()
s.push(10)
s.push(20)
s.push(30)
print("Pushed: 10, 20, 30")
print("Size: " .. s.get_size())
print("Peek: " .. s.peek())
print("Pop: " .. s.pop())
print("Pop: " .. s.pop())
print("Size after pops: " .. s.get_size())
print("")

-- Balanced parentheses
print("Balanced parentheses checker:")
local tests = {
    {"()", true},
    {"([])", true},
    {"{[()]}", true},
    {"((()))", true},
    {"(", false},
    {")(", false},
    {"([)]", false},
    {"{[(])}", false}
}

for i, test in ipairs(tests) do
    local str = test[1]
    local expected = test[2]
    local result = check_balanced(str)
    local status = (result == expected) and "PASS" or "FAIL"
    local balanced = result and "balanced" or "unbalanced"
    print(status .. ": \"" .. str .. "\" is " .. balanced)
end

print("")
print("Stack demo complete!")
