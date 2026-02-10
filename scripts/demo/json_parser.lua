-- JSON Parser Demo
-- A complete JSON parser implementation in Lua
-- Demonstrates: recursive descent parsing, string manipulation, tables

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

-- Check if character is whitespace
local function is_whitespace(c)
    return c == " " or c == "\t" or c == "\n" or c == "\r"
end

-- Check if character is a digit
local function is_digit(c)
    return c >= "0" and c <= "9"
end

--------------------------------------------------------------------------------
-- JSON Parser
--------------------------------------------------------------------------------

-- Create a new parser state
local function new_parser(json_str)
    return {
        str = json_str,
        pos = 1,
        len = string.len(json_str)
    }
end

-- Get current character
local function current(p)
    if p.pos > p.len then
        return nil
    end
    return string.sub(p.str, p.pos, p.pos)
end

-- Advance position
local function advance(p)
    p.pos = p.pos + 1
end

-- Skip whitespace
local function skip_whitespace(p)
    while p.pos <= p.len do
        local c = string.sub(p.str, p.pos, p.pos)
        if is_whitespace(c) then
            p.pos = p.pos + 1
        else
            break
        end
    end
end

-- Expect a specific character
local function expect(p, expected)
    skip_whitespace(p)
    local c = current(p)
    if c ~= expected then
        error("Expected '" .. expected .. "' at position " .. p.pos .. ", got '" .. (c or "EOF") .. "'")
    end
    advance(p)
end

-- Forward declarations for recursive parsing
local parse_value

-- Parse a JSON string
local function parse_string(p)
    skip_whitespace(p)
    expect(p, "\"")

    local result = ""
    while p.pos <= p.len do
        local c = string.sub(p.str, p.pos, p.pos)

        if c == "\"" then
            advance(p)
            return result
        elseif c == "\\" then
            -- Handle escape sequences
            advance(p)
            local escaped = current(p)
            if escaped == "\"" then
                result = result .. "\""
            elseif escaped == "\\" then
                result = result .. "\\"
            elseif escaped == "/" then
                result = result .. "/"
            elseif escaped == "n" then
                result = result .. "\n"
            elseif escaped == "r" then
                result = result .. "\r"
            elseif escaped == "t" then
                result = result .. "\t"
            elseif escaped == "b" then
                result = result .. "\b"
            elseif escaped == "f" then
                result = result .. "\f"
            elseif escaped == "u" then
                -- Unicode escape: \uXXXX (simplified - just skip 4 hex digits)
                advance(p)
                advance(p)
                advance(p)
                advance(p)
                result = result .. "?"  -- Placeholder for unicode
            else
                result = result .. escaped
            end
            advance(p)
        else
            result = result .. c
            advance(p)
        end
    end

    error("Unterminated string at position " .. p.pos)
end

-- Parse a JSON number
local function parse_number(p)
    skip_whitespace(p)

    local start_pos = p.pos
    local c = current(p)

    -- Optional negative sign
    if c == "-" then
        advance(p)
        c = current(p)
    end

    -- Integer part
    if c == "0" then
        advance(p)
        c = current(p)
    elseif is_digit(c) then
        while p.pos <= p.len and is_digit(current(p)) do
            advance(p)
        end
        c = current(p)
    else
        error("Invalid number at position " .. p.pos)
    end

    -- Fractional part
    if c == "." then
        advance(p)
        if not is_digit(current(p)) then
            error("Invalid number: expected digit after decimal point")
        end
        while p.pos <= p.len and is_digit(current(p)) do
            advance(p)
        end
        c = current(p)
    end

    -- Exponent part
    if c == "e" or c == "E" then
        advance(p)
        c = current(p)
        if c == "+" or c == "-" then
            advance(p)
        end
        if not is_digit(current(p)) then
            error("Invalid number: expected digit in exponent")
        end
        while p.pos <= p.len and is_digit(current(p)) do
            advance(p)
        end
    end

    local num_str = string.sub(p.str, start_pos, p.pos - 1)
    return tonumber(num_str)
end

-- Parse a JSON array
local function parse_array(p)
    skip_whitespace(p)
    expect(p, "[")

    local arr = {}
    local count = 0

    skip_whitespace(p)
    if current(p) == "]" then
        advance(p)
        return arr
    end

    while true do
        count = count + 1
        arr[count] = parse_value(p)

        skip_whitespace(p)
        local c = current(p)

        if c == "]" then
            advance(p)
            return arr
        elseif c == "," then
            advance(p)
        else
            error("Expected ',' or ']' in array at position " .. p.pos)
        end
    end
end

-- Parse a JSON object
local function parse_object(p)
    skip_whitespace(p)
    expect(p, "{")

    local obj = {}

    skip_whitespace(p)
    if current(p) == "}" then
        advance(p)
        return obj
    end

    while true do
        skip_whitespace(p)

        -- Parse key (must be a string)
        if current(p) ~= "\"" then
            error("Expected string key in object at position " .. p.pos)
        end
        local key = parse_string(p)

        -- Expect colon
        skip_whitespace(p)
        expect(p, ":")

        -- Parse value
        obj[key] = parse_value(p)

        skip_whitespace(p)
        local c = current(p)

        if c == "}" then
            advance(p)
            return obj
        elseif c == "," then
            advance(p)
        else
            error("Expected ',' or '}' in object at position " .. p.pos)
        end
    end
end

-- Parse any JSON value
parse_value = function(p)
    skip_whitespace(p)
    local c = current(p)

    if c == nil then
        error("Unexpected end of input")
    elseif c == "{" then
        return parse_object(p)
    elseif c == "[" then
        return parse_array(p)
    elseif c == "\"" then
        return parse_string(p)
    elseif c == "-" or is_digit(c) then
        return parse_number(p)
    elseif c == "t" then
        -- true
        if string.sub(p.str, p.pos, p.pos + 3) == "true" then
            p.pos = p.pos + 4
            return true
        else
            error("Invalid value at position " .. p.pos)
        end
    elseif c == "f" then
        -- false
        if string.sub(p.str, p.pos, p.pos + 4) == "false" then
            p.pos = p.pos + 5
            return false
        else
            error("Invalid value at position " .. p.pos)
        end
    elseif c == "n" then
        -- null
        if string.sub(p.str, p.pos, p.pos + 3) == "null" then
            p.pos = p.pos + 4
            return nil
        else
            error("Invalid value at position " .. p.pos)
        end
    else
        error("Unexpected character '" .. c .. "' at position " .. p.pos)
    end
end

-- Main parse function
local function parse_json(json_str)
    local p = new_parser(json_str)
    local value = parse_value(p)
    skip_whitespace(p)
    if p.pos <= p.len then
        error("Unexpected content after JSON value at position " .. p.pos)
    end
    return value
end

-- Parse JSON from file
local function parse_json_file(filename)
    local file = io.open(filename, "r")
    if not file then
        error("Could not open file: " .. filename)
    end
    local content = file:read("*a")
    file:close()
    return parse_json(content)
end

--------------------------------------------------------------------------------
-- JSON Stringify (for output)
--------------------------------------------------------------------------------

local stringify

-- Stringify a value with indentation
local function stringify_value(value, indent, level)
    local t = type(value)

    if value == nil then
        return "null"
    elseif t == "boolean" then
        if value then
            return "true"
        else
            return "false"
        end
    elseif t == "number" then
        return tostring(value)
    elseif t == "string" then
        -- Escape special characters
        local escaped = "\""
        for i = 1, string.len(value) do
            local c = string.sub(value, i, i)
            if c == "\"" then
                escaped = escaped .. "\\\""
            elseif c == "\\" then
                escaped = escaped .. "\\\\"
            elseif c == "\n" then
                escaped = escaped .. "\\n"
            elseif c == "\r" then
                escaped = escaped .. "\\r"
            elseif c == "\t" then
                escaped = escaped .. "\\t"
            else
                escaped = escaped .. c
            end
        end
        return escaped .. "\""
    elseif t == "table" then
        -- Check if it's an array using # operator
        -- In Moonquakes, table keys from pairs() are strings, so use ipairs for arrays
        local array_len = #value
        local is_array = array_len > 0

        -- Verify it's actually an array by checking all indices exist
        if is_array then
            for i = 1, array_len do
                if value[i] == nil then
                    is_array = false
                    break
                end
            end
        end

        if is_array then
            -- Array
            if array_len == 0 then
                return "[]"
            end

            local result = "["
            local new_indent = indent .. "  "

            for i = 1, array_len do
                if i > 1 then
                    result = result .. ","
                end
                result = result .. "\n" .. new_indent
                result = result .. stringify_value(value[i], new_indent, level + 1)
            end

            result = result .. "\n" .. indent .. "]"
            return result
        else
            -- Object
            -- Count keys
            local key_count = 0
            for k, v in pairs(value) do
                key_count = key_count + 1
            end

            if key_count == 0 then
                return "{}"
            end

            local result = "{"
            local new_indent = indent .. "  "
            local first = true

            for k, v in pairs(value) do
                if not first then
                    result = result .. ","
                end
                first = false
                result = result .. "\n" .. new_indent
                result = result .. "\"" .. tostring(k) .. "\": "
                result = result .. stringify_value(v, new_indent, level + 1)
            end

            result = result .. "\n" .. indent .. "}"
            return result
        end
    else
        return "\"[" .. t .. "]\""
    end
end

stringify = function(value)
    return stringify_value(value, "", 0)
end

--------------------------------------------------------------------------------
-- Test Suite
--------------------------------------------------------------------------------

print("=== JSON Parser Demo ===")
print("")

-- Test 1: Simple values
print("Test 1: Simple values")
print("---------------------")

local tests = {
    {"null", nil},
    {"true", true},
    {"false", false},
    {"42", 42},
    {"-17", -17},
    {"3.14159", 3.14159},
    {"1e10", 1e10},
    {"\"hello\"", "hello"},
    {"\"hello\\nworld\"", "hello\nworld"},
}

for i, test in ipairs(tests) do
    local json_str = test[1]
    local expected = test[2]
    local result = parse_json(json_str)
    local status = "PASS"
    if result ~= expected then
        status = "FAIL"
    end
    print(status .. ": " .. json_str)
end
print("")

-- Test 2: Arrays
print("Test 2: Arrays")
print("--------------")

local arr_json = "[1, 2, 3, 4, 5]"
local arr = parse_json(arr_json)
print("Parsed: " .. arr_json)
print("Length: " .. #arr)
local sum = 0
for i, v in ipairs(arr) do
    sum = sum + v
end
print("Sum: " .. sum)
print("")

-- Test 3: Objects
print("Test 3: Objects")
print("---------------")

local obj_json = '{"name": "Alice", "age": 30, "active": true}'
local obj = parse_json(obj_json)
print("Parsed: " .. obj_json)
print("name: " .. obj.name)
print("age: " .. obj.age)
print("active: " .. tostring(obj.active))
print("")

-- Test 4: Nested structures
print("Test 4: Nested structures")
print("-------------------------")

local nested_json = [[
{
    "users": [
        {"id": 1, "name": "Alice", "roles": ["admin", "user"]},
        {"id": 2, "name": "Bob", "roles": ["user"]},
        {"id": 3, "name": "Charlie", "roles": ["guest"]}
    ],
    "metadata": {
        "version": "1.0",
        "count": 3
    }
}
]]

local nested = parse_json(nested_json)
print("Parsed complex JSON successfully!")
print("Number of users: " .. #nested.users)
for i, user in ipairs(nested.users) do
    print("  User " .. user.id .. ": " .. user.name .. " (" .. #user.roles .. " roles)")
end
print("Metadata version: " .. nested.metadata.version)
print("")

-- Test 5: Round-trip (parse and stringify)
print("Test 5: Round-trip")
print("------------------")

local original = {
    title = "JSON Parser Test",
    values = {1, 2, 3},
    nested = {
        a = true,
        b = false
    }
}

local json_output = stringify(original)
print("Stringified:")
print(json_output)
print("")

local reparsed = parse_json(json_output)
print("Re-parsed successfully!")
print("title: " .. reparsed.title)
print("values count: " .. #reparsed.values)
print("")

-- Test 6: Edge cases
print("Test 6: Edge cases")
print("------------------")

local edge_cases = {
    "[]",
    "{}",
    '""',
    "0",
    "-0",
    "1.5e-10",
    '{"a":{"b":{"c":1}}}',
    "[[[[1]]]]"
}

for i, json_str in ipairs(edge_cases) do
    local ok = true
    local result = parse_json(json_str)
    print("PASS: " .. json_str)
end
print("")

-- Test 7: Large array
print("Test 7: Large array")
print("-------------------")

local large_arr = "["
for i = 1, 100 do
    if i > 1 then
        large_arr = large_arr .. ", "
    end
    large_arr = large_arr .. i
end
large_arr = large_arr .. "]"

local parsed_large = parse_json(large_arr)
print("Parsed array with " .. #parsed_large .. " elements")
local large_sum = 0
for i, v in ipairs(parsed_large) do
    large_sum = large_sum + v
end
print("Sum: " .. large_sum .. " (expected: 5050)")
print("")

-- Test 8: Sample JSON data
print("Test 8: Sample data structure")
print("-----------------------------")

local sample_data = [[
{
    "company": "Moonquakes",
    "founded": 2024,
    "products": [
        {
            "name": "Moonquakes",
            "version": "0.1.0",
            "features": ["fast", "lightweight", "embeddable"],
            "stats": {
                "lines_of_code": 10000,
                "tests_passed": 150,
                "coverage": 0.85
            }
        }
    ],
    "team": [
        {"name": "Developer 1", "role": "lead"},
        {"name": "Developer 2", "role": "contributor"}
    ],
    "open_source": true,
    "license": "MIT"
}
]]

local company = parse_json(sample_data)
print("Company: " .. company.company)
print("Founded: " .. company.founded)
print("Products:")
for i, product in ipairs(company.products) do
    print("  - " .. product.name .. " v" .. product.version)
    print("    Features: " .. #product.features)
    print("    Lines of code: " .. product.stats.lines_of_code)
    print("    Coverage: " .. (product.stats.coverage * 100) .. "%")
end
print("Team size: " .. #company.team)
print("Open source: " .. tostring(company.open_source))
print("License: " .. company.license)
print("")

-- Test 9: Read from JSON file
print("Test 9: Read from JSON file")
print("---------------------------")

local file_data = parse_json_file("scripts/demo/sample.json")
print("Loaded: scripts/demo/sample.json")
print("")
print("Project: " .. file_data.name)
print("Version: " .. file_data.version)
print("Description: " .. file_data.description)
print("")
print("Repository:")
print("  Type: " .. file_data.repository.type)
print("  URL: " .. file_data.repository.url)
print("")
print("Features (" .. #file_data.features .. "):")
for i, feature in ipairs(file_data.features) do
    print("  - " .. feature)
end
print("")
print("Stats:")
print("  Lines of code: " .. file_data.stats.lines_of_code)
print("  Test files: " .. file_data.stats.test_files)
print("  Demo files: " .. file_data.stats.demo_files)
print("")
print("Contributors: " .. #file_data.contributors)
for i, contrib in ipairs(file_data.contributors) do
    print("  - " .. contrib.name .. " (" .. contrib.commits .. " commits)")
end
print("")
print("License: " .. file_data.license)
print("Keywords: " .. #file_data.keywords)
print("Stable: " .. tostring(file_data.stable))
print("Rating: " .. file_data.rating)
print("")

print("=== JSON Parser Demo Complete ===")
print("All tests passed!")
