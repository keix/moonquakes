--[[
  inspect.lua - Human-readable value inspection

  Copyright (c) 2025 Kei Sawamura
  Licensed under the MIT License. See LICENSE file in project root.

  Usage:
    local inspect = require("std.inspect")

    print(inspect(value))
    print(inspect(value, { depth = 2 }))
    print(inspect(value, { indent = "    " }))

  Options:
    depth    - Maximum nesting depth (default: unlimited)
    indent   - Indentation string (default: "  ")
    newline  - Newline string (default: "\n")
    process  - Custom processor function(item, path) -> item, override
]]

local inspect = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local KEY_ORDER = {
    "number", "string", "boolean"
}

local ESCAPE_MAP = {
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
    ["\\"] = "\\\\",
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function escape_string(str)
    local result = str:gsub("[\a\b\f\n\r\t\v\\]", ESCAPE_MAP)
    result = result:gsub("[%c]", function(c)
        return string.format("\\x%02x", string.byte(c))
    end)
    return result
end

local function smart_quote(str)
    local has_single = str:find("'")
    local has_double = str:find('"')

    if has_double and not has_single then
        return "'" .. escape_string(str) .. "'"
    else
        return '"' .. escape_string(str):gsub('"', '\\"') .. '"'
    end
end

local function is_identifier(str)
    return type(str) == "string" and str:match("^[%a_][%w_]*$") ~= nil
end

local function sort_keys(a, b)
    local ta, tb = type(a), type(b)

    if ta == tb then
        if ta == "number" or ta == "string" then
            return a < b
        else
            return tostring(a) < tostring(b)
        end
    end

    -- Order: number, string, boolean, others
    local order = { number = 1, string = 2, boolean = 3 }
    local oa = order[ta] or 4
    local ob = order[tb] or 4

    if oa == ob then
        return tostring(a) < tostring(b)
    end
    return oa < ob
end

local function get_sorted_keys(tbl)
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys, sort_keys)
    return keys
end

local function is_sequence(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    for i = 1, count do
        if tbl[i] == nil then
            return false
        end
    end
    return count > 0
end

local function count_keys(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

--------------------------------------------------------------------------------
-- Inspector
--------------------------------------------------------------------------------

local function make_inspector(opts)
    local depth = opts.depth
    local indent = opts.indent or "  "
    local newline = opts.newline or "\n"
    local process = opts.process
    local seen = {}
    local output = {}

    local function write(str)
        output[#output + 1] = str
    end

    local function inspect_value(value, current_depth, path)
        -- Custom processor
        if process then
            local new_value, override = process(value, path)
            if override then
                write(tostring(override))
                return
            end
            value = new_value
        end

        local vtype = type(value)

        if vtype == "nil" then
            write("nil")

        elseif vtype == "boolean" then
            write(value and "true" or "false")

        elseif vtype == "number" then
            if value ~= value then
                write("nan")
            elseif value == math.huge then
                write("inf")
            elseif value == -math.huge then
                write("-inf")
            elseif value == math.floor(value) then
                write(string.format("%.0f", value))
            else
                write(tostring(value))
            end

        elseif vtype == "string" then
            write(smart_quote(value))

        elseif vtype == "function" then
            local info = debug.getinfo(value, "S")
            if info and info.what == "Lua" then
                write(string.format("<function: %s:%d>", info.short_src or "?", info.linedefined or 0))
            else
                write(string.format("<function: %s>", tostring(value):match("0x%x+") or "?"))
            end

        elseif vtype == "thread" then
            write(string.format("<thread: %s>", tostring(value):match("0x%x+") or "?"))

        elseif vtype == "userdata" then
            local mt = getmetatable(value)
            if mt and mt.__tostring then
                write(string.format("<userdata: %s>", tostring(value)))
            else
                write(string.format("<userdata: %s>", tostring(value):match("0x%x+") or "?"))
            end

        elseif vtype == "table" then
            -- Cycle detection
            if seen[value] then
                write(string.format("<cycle: %s>", tostring(value):match("0x%x+") or "?"))
                return
            end

            -- Depth limit
            if depth and current_depth >= depth then
                write("{...}")
                return
            end

            seen[value] = true

            -- Check metatable __tostring
            local mt = getmetatable(value)
            local mt_name = mt and rawget(mt, "__name")

            -- Empty table
            if count_keys(value) == 0 then
                if mt_name then
                    write(string.format("<%s> {}", mt_name))
                else
                    write("{}")
                end
                seen[value] = nil
                return
            end

            -- Prefix with metatable name if present
            if mt_name then
                write(string.format("<%s> ", mt_name))
            end

            local is_seq = is_sequence(value)
            local keys = get_sorted_keys(value)
            local current_indent = string.rep(indent, current_depth)
            local next_indent = string.rep(indent, current_depth + 1)

            write("{")

            for i, key in ipairs(keys) do
                local val = value[key]
                local key_path = path and (path .. "." .. tostring(key)) or tostring(key)

                write(newline)
                write(next_indent)

                -- Key
                if is_seq and type(key) == "number" then
                    -- Array-style: just value
                else
                    if is_identifier(key) then
                        write(key)
                    elseif type(key) == "string" then
                        write("[")
                        write(smart_quote(key))
                        write("]")
                    else
                        write("[")
                        inspect_value(key, current_depth + 1, key_path)
                        write("]")
                    end
                    write(" = ")
                end

                -- Value
                inspect_value(val, current_depth + 1, key_path)

                if i < #keys then
                    write(",")
                end
            end

            write(newline)
            write(current_indent)
            write("}")

            seen[value] = nil
        else
            write(string.format("<%s>", tostring(value)))
        end
    end

    return function(value)
        inspect_value(value, 0, nil)
        return table.concat(output)
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

setmetatable(inspect, {
    __call = function(_, value, opts)
        opts = opts or {}
        local inspector = make_inspector(opts)
        return inspector(value)
    end
})

-- Shorthand for depth-limited inspect
function inspect.shallow(value, max_depth)
    return inspect(value, { depth = max_depth or 1 })
end

-- Inspect with custom filter
function inspect.filter(value, filter_fn)
    return inspect(value, {
        process = function(item, path)
            if filter_fn(item, path) then
                return item
            else
                return nil, "<filtered>"
            end
        end
    })
end

-- Compact single-line output
function inspect.compact(value)
    local result = inspect(value, { indent = "", newline = " " })
    return result:gsub("%s+", " "):gsub("{ ", "{"):gsub(" }", "}")
end

-- Print and return (for debugging chains)
function inspect.p(value, label)
    if label then
        print(label .. ": " .. inspect(value))
    else
        print(inspect(value))
    end
    return value
end

-- Diff two values
function inspect.diff(a, b, path)
    path = path or "root"
    local diffs = {}

    local function add_diff(p, va, vb)
        diffs[#diffs + 1] = {
            path = p,
            a = va,
            b = vb,
        }
    end

    local function diff_values(va, vb, p)
        local ta, tb = type(va), type(vb)

        if ta ~= tb then
            add_diff(p, va, vb)
            return
        end

        if ta ~= "table" then
            if va ~= vb then
                add_diff(p, va, vb)
            end
            return
        end

        -- Both tables
        local all_keys = {}
        for k in pairs(va) do all_keys[k] = true end
        for k in pairs(vb) do all_keys[k] = true end

        for k in pairs(all_keys) do
            local key_str = type(k) == "string" and k or ("[" .. tostring(k) .. "]")
            diff_values(va[k], vb[k], p .. "." .. key_str)
        end
    end

    diff_values(a, b, path)

    if #diffs == 0 then
        return nil
    end

    local result = {}
    for _, d in ipairs(diffs) do
        result[#result + 1] = string.format("%s:\n  - %s\n  + %s",
            d.path,
            inspect.compact(d.a),
            inspect.compact(d.b))
    end
    return table.concat(result, "\n")
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

function inspect.test()
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

    local function assert_contains(str, pattern, msg)
        if not str:find(pattern, 1, true) then
            error(string.format("%s: expected '%s' in '%s'", msg or "assertion failed", pattern, str))
        end
    end

    local function assert_eq(a, b, msg)
        if a ~= b then
            error(string.format("%s: expected '%s', got '%s'", msg or "assertion failed", tostring(b), tostring(a)))
        end
    end

    print("Running inspect tests...")

    test("nil", function()
        assert_eq(inspect(nil), "nil")
    end)

    test("booleans", function()
        assert_eq(inspect(true), "true")
        assert_eq(inspect(false), "false")
    end)

    test("numbers", function()
        assert_eq(inspect(42), "42")
        assert_eq(inspect(-17), "-17")
        assert_contains(inspect(3.14), "3.14")
        assert_eq(inspect(1/0), "inf")
        assert_eq(inspect(-1/0), "-inf")
        assert_eq(inspect(0/0), "nan")
    end)

    test("strings", function()
        assert_eq(inspect("hello"), '"hello"')
        assert_eq(inspect("say \"hi\""), "'say \"hi\"'")
        assert_contains(inspect("line\nbreak"), "\\n")
    end)

    test("empty table", function()
        assert_eq(inspect({}), "{}")
    end)

    test("array", function()
        local result = inspect({1, 2, 3})
        assert_contains(result, "1")
        assert_contains(result, "2")
        assert_contains(result, "3")
    end)

    test("object", function()
        local result = inspect({a = 1, b = 2})
        assert_contains(result, "a = 1")
        assert_contains(result, "b = 2")
    end)

    test("nested", function()
        local result = inspect({outer = {inner = "value"}})
        assert_contains(result, "outer")
        assert_contains(result, "inner")
        assert_contains(result, '"value"')
    end)

    test("cycle detection", function()
        local t = {a = 1}
        t.self = t
        local result = inspect(t)
        assert_contains(result, "<cycle:")
    end)

    test("depth limit", function()
        local result = inspect({a = {b = {c = 1}}}, {depth = 1})
        assert_contains(result, "{...}")
    end)

    test("function", function()
        local result = inspect(function() end)
        assert_contains(result, "<function:")
    end)

    test("compact", function()
        local result = inspect.compact({a = 1, b = 2})
        assert(not result:find("\n"), "should not contain newlines")
    end)

    test("diff equal", function()
        local result = inspect.diff({a = 1}, {a = 1})
        assert_eq(result, nil)
    end)

    test("diff different", function()
        local result = inspect.diff({a = 1}, {a = 2})
        assert_contains(result, "a")
        assert_contains(result, "1")
        assert_contains(result, "2")
    end)

    print(string.format("\nTests: %d passed, %d failed", tests_passed, tests_failed))
    return tests_failed == 0
end

return inspect
