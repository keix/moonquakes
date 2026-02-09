-- Simple Expression Calculator Demo
-- Demonstrates string parsing and recursion

-- Tokenizer
local function tokenize(expr)
    local tokens = {}
    local count = 0
    local i = 1
    local len = string.len(expr)

    while i <= len do
        local c = string.sub(expr, i, i)

        -- Skip whitespace
        if c == " " then
            i = i + 1
        -- Operators and parentheses
        elseif c == "+" or c == "-" or c == "*" or c == "/" or
               c == "(" or c == ")" or c == "^" or c == "%" then
            count = count + 1
            tokens[count] = {type = "op", value = c}
            i = i + 1
        -- Numbers
        elseif c >= "0" and c <= "9" then
            local num = ""
            while i <= len do
                c = string.sub(expr, i, i)
                if (c >= "0" and c <= "9") or c == "." then
                    num = num .. c
                    i = i + 1
                else
                    break
                end
            end
            count = count + 1
            tokens[count] = {type = "num", value = tonumber(num)}
        else
            i = i + 1
        end
    end

    return tokens
end

-- Recursive descent parser
local parse_expr  -- forward declaration

local function parse_number(tokens, pos)
    local tok = tokens[pos]
    if tok and tok.type == "num" then
        return tok.value, pos + 1
    elseif tok and tok.type == "op" and tok.value == "(" then
        local val, new_pos = parse_expr(tokens, pos + 1)
        local close = tokens[new_pos]
        if close and close.type == "op" and close.value == ")" then
            new_pos = new_pos + 1
        end
        return val, new_pos
    elseif tok and tok.type == "op" and tok.value == "-" then
        local val, new_pos = parse_number(tokens, pos + 1)
        return -val, new_pos
    end
    return 0, pos
end

local function parse_factor(tokens, pos)
    local left, new_pos = parse_number(tokens, pos)
    local tok = tokens[new_pos]
    while tok and tok.type == "op" and tok.value == "^" do
        local right
        right, new_pos = parse_number(tokens, new_pos + 1)
        left = left ^ right
        tok = tokens[new_pos]
    end
    return left, new_pos
end

local function parse_term(tokens, pos)
    local left, new_pos = parse_factor(tokens, pos)
    local tok = tokens[new_pos]
    while tok and tok.type == "op" and (tok.value == "*" or tok.value == "/" or tok.value == "%") do
        local op = tok.value
        local right
        right, new_pos = parse_factor(tokens, new_pos + 1)
        if op == "*" then
            left = left * right
        elseif op == "/" then
            left = left / right
        else
            left = left % right
        end
        tok = tokens[new_pos]
    end
    return left, new_pos
end

parse_expr = function(tokens, pos)
    local left, new_pos = parse_term(tokens, pos)
    local tok = tokens[new_pos]
    while tok and tok.type == "op" and (tok.value == "+" or tok.value == "-") do
        local op = tok.value
        local right
        right, new_pos = parse_term(tokens, new_pos + 1)
        if op == "+" then
            left = left + right
        else
            left = left - right
        end
        tok = tokens[new_pos]
    end
    return left, new_pos
end

-- Evaluate expression string
local function eval(expr)
    local tokens = tokenize(expr)
    local result, _ = parse_expr(tokens, 1)
    return result
end

-- Main
print("=== Expression Calculator Demo ===")
print("")

local expressions = {
    "1 + 2",
    "10 - 3 * 2",
    "(10 - 3) * 2",
    "2 ^ 10",
    "100 / 4 / 5",
    "17 % 5",
    "2 + 3 * 4 - 5",
    "(2 + 3) * (4 - 1)",
    "2 ^ 3 ^ 2",
    "-5 + 10",
    "3.14 * 2",
    "((1 + 2) * 3 + 4) * 5"
}

for i, expr in ipairs(expressions) do
    local result = eval(expr)
    print(expr .. " = " .. result)
end

print("")
print("Calculator demo complete!")
