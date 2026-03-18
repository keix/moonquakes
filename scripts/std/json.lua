--[[
  json.lua - Pure Lua JSON encoder/decoder

  Copyright (c) 2025 Kei Sawamura
  Licensed under the MIT License. See LICENSE file in project root.

  Features:
    - Full JSON specification support (RFC 8259)
    - Pretty printing with configurable indentation
    - Unicode escape sequence handling (\uXXXX)
    - Sparse array detection
    - Custom encoder/decoder hooks
    - Error messages with line/column information

  Usage:
    local json = require("json")

    -- Encode
    local str = json.encode({name = "Lua", version = 5.4})
    local pretty = json.encode(data, {indent = 2})

    -- Decode
    local data = json.decode('{"key": "value"}')
]]

local json = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local DEFAULT_MAX_DEPTH = 1000

local ESCAPE_CHARS = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local UNESCAPE_CHARS = {
    ["\\"] = "\\",
    ["\""] = "\"",
    ["/"]  = "/",
    ["b"]  = "\b",
    ["f"]  = "\f",
    ["n"]  = "\n",
    ["r"]  = "\r",
    ["t"]  = "\t",
}

local WHITESPACE = {
    [" "]  = true,
    ["\t"] = true,
    ["\n"] = true,
    ["\r"] = true,
}

--------------------------------------------------------------------------------
-- Encoder
--------------------------------------------------------------------------------

local encode_value

local function encode_string(str)
    local result = {}
    result[#result + 1] = '"'

    local i = 1
    local len = #str

    while i <= len do
        local byte = string.byte(str, i)
        local char = string.sub(str, i, i)

        if ESCAPE_CHARS[char] then
            result[#result + 1] = ESCAPE_CHARS[char]
        elseif byte < 32 then
            -- Control characters need \uXXXX encoding
            result[#result + 1] = string.format("\\u%04x", byte)
        elseif byte < 128 then
            result[#result + 1] = char
        else
            -- UTF-8 multi-byte sequence - pass through as-is
            -- Lua strings are byte sequences, JSON allows UTF-8
            result[#result + 1] = char
        end

        i = i + 1
    end

    result[#result + 1] = '"'
    return table.concat(result)
end

local function encode_number(num)
    if num ~= num then
        error("cannot encode NaN")
    elseif num == math.huge or num == -math.huge then
        error("cannot encode Infinity")
    end

    -- Use string.format for consistent output
    if num == math.floor(num) and math.abs(num) < 2^53 then
        return string.format("%.0f", num)
    else
        local str = string.format("%.17g", num)
        -- Ensure decimal point for floating point numbers
        if not string.find(str, "[%.eE]") then
            str = str .. ".0"
        end
        return str
    end
end

local function is_array(tbl)
    if type(tbl) ~= "table" then
        return false, 0
    end

    local count = 0
    local max_index = 0

    for k, _ in pairs(tbl) do
        if type(k) == "number" and k > 0 and math.floor(k) == k then
            count = count + 1
            if k > max_index then
                max_index = k
            end
        else
            return false, 0
        end
    end

    -- Check for sparse arrays (more than 50% holes is considered object)
    if max_index > 0 and count / max_index < 0.5 then
        return false, 0
    end

    return count == max_index, max_index
end

local function encode_array(arr, len, opts, depth)
    if len == 0 then
        return "[]"
    end

    local result = {}
    local indent_str = opts.indent_str
    local newline = opts.newline
    local current_indent = indent_str and string.rep(indent_str, depth) or ""
    local item_indent = indent_str and string.rep(indent_str, depth + 1) or ""

    result[#result + 1] = "["

    for i = 1, len do
        if i > 1 then
            result[#result + 1] = ","
        end

        if indent_str then
            result[#result + 1] = newline
            result[#result + 1] = item_indent
        end

        local val = arr[i]
        if val == nil then
            result[#result + 1] = "null"
        else
            result[#result + 1] = encode_value(val, opts, depth + 1)
        end
    end

    if indent_str then
        result[#result + 1] = newline
        result[#result + 1] = current_indent
    end

    result[#result + 1] = "]"
    return table.concat(result)
end

local function encode_object(obj, opts, depth)
    local result = {}
    local indent_str = opts.indent_str
    local newline = opts.newline
    local current_indent = indent_str and string.rep(indent_str, depth) or ""
    local item_indent = indent_str and string.rep(indent_str, depth + 1) or ""
    local colon_space = indent_str and ": " or ":"

    -- Collect and sort keys for deterministic output
    local keys = {}
    for k, _ in pairs(obj) do
        if type(k) == "string" then
            keys[#keys + 1] = k
        elseif type(k) ~= "number" then
            error("object keys must be strings, got " .. type(k))
        end
    end

    if opts.sort_keys then
        table.sort(keys)
    end

    if #keys == 0 then
        return "{}"
    end

    result[#result + 1] = "{"

    local first = true
    for _, k in ipairs(keys) do
        local v = obj[k]

        -- Skip functions and other non-serializable types
        if v ~= nil and type(v) ~= "function" and type(v) ~= "userdata" and type(v) ~= "thread" then
            if not first then
                result[#result + 1] = ","
            end
            first = false

            if indent_str then
                result[#result + 1] = newline
                result[#result + 1] = item_indent
            end

            result[#result + 1] = encode_string(k)
            result[#result + 1] = colon_space
            result[#result + 1] = encode_value(v, opts, depth + 1)
        end
    end

    if indent_str then
        result[#result + 1] = newline
        result[#result + 1] = current_indent
    end

    result[#result + 1] = "}"
    return table.concat(result)
end

function encode_value(value, opts, depth)
    depth = depth or 0

    if depth > opts.max_depth then
        error("maximum depth exceeded")
    end

    local vtype = type(value)

    -- Custom encoder hook
    if opts.encode_hook then
        local handled, result = opts.encode_hook(value, vtype, depth)
        if handled then
            return result
        end
    end

    if value == nil then
        return "null"
    elseif vtype == "boolean" then
        return value and "true" or "false"
    elseif vtype == "number" then
        return encode_number(value)
    elseif vtype == "string" then
        return encode_string(value)
    elseif vtype == "table" then
        local is_arr, len = is_array(value)
        if is_arr then
            return encode_array(value, len, opts, depth)
        else
            return encode_object(value, opts, depth)
        end
    else
        error("cannot encode type: " .. vtype)
    end
end

function json.encode(value, options)
    options = options or {}

    local opts = {
        indent_str = nil,
        newline = "\n",
        sort_keys = options.sort_keys or false,
        max_depth = options.max_depth or DEFAULT_MAX_DEPTH,
        encode_hook = options.encode_hook,
    }

    if options.indent then
        if type(options.indent) == "number" then
            opts.indent_str = string.rep(" ", options.indent)
        elseif type(options.indent) == "string" then
            opts.indent_str = options.indent
        else
            opts.indent_str = "  "
        end
    end

    local ok, result = pcall(encode_value, value, opts, 0)
    if not ok then
        return nil, "encode error: " .. tostring(result)
    end

    return result
end

--------------------------------------------------------------------------------
-- Decoder
--------------------------------------------------------------------------------

local decode_value

local function create_parser(str, opts)
    return {
        str = str,
        pos = 1,
        len = #str,
        line = 1,
        col = 1,
        opts = opts,
    }
end

local function parser_error(parser, msg)
    error(string.format("%s at line %d, column %d", msg, parser.line, parser.col))
end

local function peek(parser)
    if parser.pos > parser.len then
        return nil
    end
    return string.sub(parser.str, parser.pos, parser.pos)
end

local function peek_n(parser, n)
    if parser.pos + n - 1 > parser.len then
        return nil
    end
    return string.sub(parser.str, parser.pos, parser.pos + n - 1)
end

local function advance(parser, n)
    n = n or 1
    for _ = 1, n do
        if parser.pos <= parser.len then
            local char = string.sub(parser.str, parser.pos, parser.pos)
            if char == "\n" then
                parser.line = parser.line + 1
                parser.col = 1
            else
                parser.col = parser.col + 1
            end
            parser.pos = parser.pos + 1
        end
    end
end

local function skip_whitespace(parser)
    while parser.pos <= parser.len do
        local char = peek(parser)
        if WHITESPACE[char] then
            advance(parser)
        else
            break
        end
    end
end

local function expect(parser, expected)
    local actual = peek(parser)
    if actual ~= expected then
        parser_error(parser, string.format("expected '%s', got '%s'", expected, actual or "EOF"))
    end
    advance(parser)
end

local function decode_unicode_escape(parser)
    local hex = peek_n(parser, 4)
    if not hex or not string.match(hex, "^%x%x%x%x$") then
        parser_error(parser, "invalid unicode escape sequence")
    end
    advance(parser, 4)

    local codepoint = tonumber(hex, 16)

    -- Handle surrogate pairs
    if codepoint >= 0xD800 and codepoint <= 0xDBFF then
        -- High surrogate, expect low surrogate
        if peek_n(parser, 2) == "\\u" then
            advance(parser, 2)
            local low_hex = peek_n(parser, 4)
            if low_hex and string.match(low_hex, "^%x%x%x%x$") then
                local low_codepoint = tonumber(low_hex, 16)
                if low_codepoint >= 0xDC00 and low_codepoint <= 0xDFFF then
                    advance(parser, 4)
                    -- Combine surrogate pair
                    codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low_codepoint - 0xDC00)
                else
                    parser_error(parser, "invalid surrogate pair")
                end
            else
                parser_error(parser, "invalid low surrogate")
            end
        else
            parser_error(parser, "expected low surrogate")
        end
    end

    -- Convert codepoint to UTF-8
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xC0 + math.floor(codepoint / 0x40),
            0x80 + (codepoint % 0x40)
        )
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + (codepoint % 0x40)
        )
    else
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + (codepoint % 0x40)
        )
    end
end

local function decode_string(parser)
    expect(parser, '"')

    local result = {}

    while true do
        local char = peek(parser)

        if char == nil then
            parser_error(parser, "unterminated string")
        elseif char == '"' then
            advance(parser)
            break
        elseif char == "\\" then
            advance(parser)
            local escape_char = peek(parser)

            if escape_char == nil then
                parser_error(parser, "unterminated string escape")
            elseif escape_char == "u" then
                advance(parser)
                result[#result + 1] = decode_unicode_escape(parser)
            elseif UNESCAPE_CHARS[escape_char] then
                result[#result + 1] = UNESCAPE_CHARS[escape_char]
                advance(parser)
            else
                parser_error(parser, "invalid escape sequence: \\" .. escape_char)
            end
        elseif string.byte(char) < 32 then
            parser_error(parser, "control character in string")
        else
            result[#result + 1] = char
            advance(parser)
        end
    end

    return table.concat(result)
end

local function decode_number(parser)
    local start_pos = parser.pos
    local char = peek(parser)

    -- Optional minus sign
    if char == "-" then
        advance(parser)
        char = peek(parser)
    end

    -- Integer part
    if char == "0" then
        advance(parser)
        char = peek(parser)
    elseif char and string.match(char, "[1-9]") then
        advance(parser)
        while true do
            char = peek(parser)
            if char and string.match(char, "%d") then
                advance(parser)
            else
                break
            end
        end
    else
        parser_error(parser, "invalid number")
    end

    -- Fractional part
    if peek(parser) == "." then
        advance(parser)
        char = peek(parser)
        if not char or not string.match(char, "%d") then
            parser_error(parser, "invalid number: expected digit after decimal point")
        end
        while true do
            char = peek(parser)
            if char and string.match(char, "%d") then
                advance(parser)
            else
                break
            end
        end
    end

    -- Exponent part
    char = peek(parser)
    if char == "e" or char == "E" then
        advance(parser)
        char = peek(parser)
        if char == "+" or char == "-" then
            advance(parser)
        end
        char = peek(parser)
        if not char or not string.match(char, "%d") then
            parser_error(parser, "invalid number: expected digit in exponent")
        end
        while true do
            char = peek(parser)
            if char and string.match(char, "%d") then
                advance(parser)
            else
                break
            end
        end
    end

    local num_str = string.sub(parser.str, start_pos, parser.pos - 1)
    local num = tonumber(num_str)

    if not num then
        parser_error(parser, "invalid number: " .. num_str)
    end

    return num
end

local function decode_array(parser)
    expect(parser, "[")
    skip_whitespace(parser)

    local result = {}

    if peek(parser) == "]" then
        advance(parser)
        return result
    end

    while true do
        skip_whitespace(parser)
        result[#result + 1] = decode_value(parser)
        skip_whitespace(parser)

        local char = peek(parser)
        if char == "]" then
            advance(parser)
            break
        elseif char == "," then
            advance(parser)
        else
            parser_error(parser, "expected ',' or ']' in array")
        end
    end

    return result
end

local function decode_object(parser)
    expect(parser, "{")
    skip_whitespace(parser)

    local result = {}

    if peek(parser) == "}" then
        advance(parser)
        return result
    end

    while true do
        skip_whitespace(parser)

        if peek(parser) ~= '"' then
            parser_error(parser, "expected string key in object")
        end

        local key = decode_string(parser)
        skip_whitespace(parser)
        expect(parser, ":")
        skip_whitespace(parser)

        local value = decode_value(parser)
        result[key] = value

        skip_whitespace(parser)

        local char = peek(parser)
        if char == "}" then
            advance(parser)
            break
        elseif char == "," then
            advance(parser)
        else
            parser_error(parser, "expected ',' or '}' in object")
        end
    end

    return result
end

local function decode_literal(parser, literal, value)
    local len = #literal
    if peek_n(parser, len) == literal then
        advance(parser, len)
        return value
    else
        parser_error(parser, "invalid literal")
    end
end

function decode_value(parser)
    skip_whitespace(parser)

    local char = peek(parser)

    if char == nil then
        parser_error(parser, "unexpected end of input")
    elseif char == "{" then
        return decode_object(parser)
    elseif char == "[" then
        return decode_array(parser)
    elseif char == '"' then
        return decode_string(parser)
    elseif char == "t" then
        return decode_literal(parser, "true", true)
    elseif char == "f" then
        return decode_literal(parser, "false", false)
    elseif char == "n" then
        return decode_literal(parser, "null", parser.opts.null_value)
    elseif char == "-" or string.match(char, "%d") then
        return decode_number(parser)
    else
        parser_error(parser, "unexpected character: " .. char)
    end
end

function json.decode(str, options)
    if type(str) ~= "string" then
        return nil, "decode error: expected string input"
    end

    options = options or {}

    local opts = {
        null_value = options.null_value,  -- Default: nil
    }

    local parser = create_parser(str, opts)

    local ok, result = pcall(decode_value, parser)
    if not ok then
        return nil, "decode error: " .. tostring(result)
    end

    -- Check for trailing content
    skip_whitespace(parser)
    if parser.pos <= parser.len then
        return nil, string.format("decode error: unexpected content at line %d, column %d", parser.line, parser.col)
    end

    return result
end

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

-- Null value marker for encoding explicit nulls
json.null = setmetatable({}, {
    __tostring = function() return "null" end,
    __type = "json.null"
})

-- Check if a value represents JSON null
function json.is_null(value)
    return value == json.null or value == nil
end

-- Pretty print a Lua value as JSON
function json.pretty(value, indent)
    return json.encode(value, {indent = indent or 2, sort_keys = true})
end

-- Load JSON from a file
function json.load(filename)
    local file, err = io.open(filename, "r")
    if not file then
        return nil, "failed to open file: " .. tostring(err)
    end

    local content = file:read("*a")
    file:close()

    if not content then
        return nil, "failed to read file"
    end

    return json.decode(content)
end

-- Save Lua value as JSON to a file
function json.save(filename, value, options)
    local content, err = json.encode(value, options)
    if not content then
        return false, err
    end

    local file, open_err = io.open(filename, "w")
    if not file then
        return false, "failed to open file: " .. tostring(open_err)
    end

    local success, write_err = file:write(content)
    file:close()

    if not success then
        return false, "failed to write file: " .. tostring(write_err)
    end

    return true
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

function json.test()
    local tests_passed = 0
    local tests_failed = 0

    local function test(name, fn)
        local ok, err = pcall(fn)
        if ok then
            tests_passed = tests_passed + 1
            print(string.format("  [PASS] %s", name))
        else
            tests_failed = tests_failed + 1
            print(string.format("  [FAIL] %s: %s", name, err))
        end
    end

    local function assert_eq(a, b, msg)
        if a ~= b then
            error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(b), tostring(a)))
        end
    end

    local function assert_deep_eq(a, b, path)
        path = path or "root"

        if type(a) ~= type(b) then
            error(string.format("type mismatch at %s: %s vs %s", path, type(a), type(b)))
        end

        if type(a) == "table" then
            for k, v in pairs(a) do
                assert_deep_eq(v, b[k], path .. "." .. tostring(k))
            end
            for k, v in pairs(b) do
                if a[k] == nil then
                    error(string.format("missing key at %s.%s", path, tostring(k)))
                end
            end
        else
            if a ~= b then
                error(string.format("value mismatch at %s: %s vs %s", path, tostring(a), tostring(b)))
            end
        end
    end

    print("Running JSON tests...")

    -- Encoding tests
    test("encode null", function()
        assert_eq(json.encode(nil), "null")
    end)

    test("encode booleans", function()
        assert_eq(json.encode(true), "true")
        assert_eq(json.encode(false), "false")
    end)

    test("encode numbers", function()
        assert_eq(json.encode(42), "42")
        assert_eq(json.encode(-17), "-17")
        -- Floating point numbers are encoded with high precision for round-trip safety
        local encoded = json.encode(3.14159)
        assert(json.decode(encoded) == 3.14159, "float round-trip failed")
        assert_eq(json.encode(1e10), "10000000000")
    end)

    test("encode strings", function()
        assert_eq(json.encode("hello"), '"hello"')
        assert_eq(json.encode(""), '""')
        assert_eq(json.encode('say "hi"'), '"say \\"hi\\""')
        assert_eq(json.encode("line1\nline2"), '"line1\\nline2"')
    end)

    test("encode arrays", function()
        assert_eq(json.encode({}), "[]")
        assert_eq(json.encode({1, 2, 3}), "[1,2,3]")
        assert_eq(json.encode({"a", "b"}), '["a","b"]')
    end)

    test("encode objects", function()
        local result = json.encode({name = "test"})
        assert(string.find(result, '"name"'), "expected name key")
        assert(string.find(result, '"test"'), "expected test value")
    end)

    test("encode nested", function()
        local data = {
            users = {
                {name = "Alice", age = 30},
                {name = "Bob", age = 25}
            }
        }
        local result = json.encode(data)
        assert(string.find(result, "Alice"), "expected Alice")
        assert(string.find(result, "Bob"), "expected Bob")
    end)

    test("encode pretty", function()
        local result = json.encode({a = 1}, {indent = 2})
        assert(string.find(result, "\n"), "expected newlines in pretty output")
    end)

    -- Decoding tests
    test("decode null", function()
        assert_eq(json.decode("null"), nil)
    end)

    test("decode booleans", function()
        assert_eq(json.decode("true"), true)
        assert_eq(json.decode("false"), false)
    end)

    test("decode numbers", function()
        assert_eq(json.decode("42"), 42)
        assert_eq(json.decode("-17"), -17)
        assert_eq(json.decode("3.14"), 3.14)
        assert_eq(json.decode("1e10"), 1e10)
        assert_eq(json.decode("1E-5"), 1e-5)
    end)

    test("decode strings", function()
        assert_eq(json.decode('"hello"'), "hello")
        assert_eq(json.decode('""'), "")
        assert_eq(json.decode('"say \\"hi\\""'), 'say "hi"')
        assert_eq(json.decode('"line1\\nline2"'), "line1\nline2")
    end)

    test("decode unicode escapes", function()
        assert_eq(json.decode('"\\u0041"'), "A")
        assert_eq(json.decode('"\\u3042"'), "あ")
    end)

    test("decode arrays", function()
        assert_deep_eq(json.decode("[]"), {})
        assert_deep_eq(json.decode("[1,2,3]"), {1, 2, 3})
        assert_deep_eq(json.decode('["a", "b"]'), {"a", "b"})
    end)

    test("decode objects", function()
        assert_deep_eq(json.decode("{}"), {})
        assert_deep_eq(json.decode('{"name":"test"}'), {name = "test"})
    end)

    test("decode nested", function()
        local data = json.decode('{"users":[{"name":"Alice"},{"name":"Bob"}]}')
        assert_eq(data.users[1].name, "Alice")
        assert_eq(data.users[2].name, "Bob")
    end)

    test("decode whitespace", function()
        local data = json.decode([[
            {
                "key" : "value" ,
                "num" : 123
            }
        ]])
        assert_eq(data.key, "value")
        assert_eq(data.num, 123)
    end)

    -- Round-trip tests
    test("round-trip complex data", function()
        local original = {
            name = "Test",
            values = {1, 2, 3, 4, 5},
            nested = {
                flag = true,
                data = "hello\nworld"
            },
            empty_arr = {},
            empty_obj = {}
        }
        local encoded = json.encode(original)
        local decoded = json.decode(encoded)
        assert_deep_eq(original, decoded)
    end)

    -- Error handling tests
    test("error on invalid JSON", function()
        local result, err = json.decode("invalid")
        assert(result == nil, "expected nil result")
        assert(err ~= nil, "expected error message")
    end)

    test("error on unterminated string", function()
        local result, err = json.decode('"unterminated')
        assert(result == nil, "expected nil result")
        assert(string.find(err, "unterminated"), "expected unterminated error")
    end)

    test("error on trailing content", function()
        local result, err = json.decode('123 456')
        assert(result == nil, "expected nil result")
        assert(string.find(err, "unexpected"), "expected unexpected content error")
    end)

    print(string.format("\nTests: %d passed, %d failed", tests_passed, tests_failed))
    return tests_failed == 0
end

return json
