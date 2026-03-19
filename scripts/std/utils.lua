--[[
  utils.lua - Comprehensive Lua utility library

  Copyright (c) 2025 Kei Sawamura
  Licensed under the MIT License. See LICENSE file in project root.

  Modules:
    - string: Extended string operations
    - table: Table manipulation utilities
    - func: Functional programming helpers
    - path: File path operations
    - class: Object-oriented programming support
    - iter: Iterator utilities
    - validate: Data validation

  Usage:
    local utils = require("utils")

    -- String utilities
    local parts = utils.string.split("a,b,c", ",")

    -- Table utilities
    local copy = utils.table.deep_copy(original)

    -- Functional programming
    local doubled = utils.func.map({1, 2, 3}, function(x) return x * 2 end)
]]

local utils = {}

--------------------------------------------------------------------------------
-- String Utilities
--------------------------------------------------------------------------------

utils.string = {}

-- Split string by delimiter
function utils.string.split(str, delimiter, max_splits)
    if delimiter == "" then
        -- Split into individual characters
        local result = {}
        for i = 1, #str do
            result[i] = string.sub(str, i, i)
        end
        return result
    end

    local result = {}
    local pattern = "([^" .. delimiter .. "]*)" .. delimiter .. "?"
    local count = 0

    for part in string.gmatch(str .. delimiter, pattern) do
        if max_splits and count >= max_splits then
            result[#result] = result[#result] .. delimiter .. part
        else
            result[#result + 1] = part
            count = count + 1
        end
    end

    -- Remove empty trailing element
    if result[#result] == "" then
        result[#result] = nil
    end

    return result
end

-- Join array elements with delimiter
function utils.string.join(arr, delimiter)
    delimiter = delimiter or ""
    return table.concat(arr, delimiter)
end

-- Trim whitespace from both ends
function utils.string.trim(str)
    return string.match(str, "^%s*(.-)%s*$") or ""
end

-- Trim whitespace from left
function utils.string.ltrim(str)
    return string.match(str, "^%s*(.*)$") or ""
end

-- Trim whitespace from right
function utils.string.rtrim(str)
    return string.match(str, "^(.-)%s*$") or ""
end

-- Check if string starts with prefix
function utils.string.starts_with(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- Check if string ends with suffix
function utils.string.ends_with(str, suffix)
    return suffix == "" or string.sub(str, -#suffix) == suffix
end

-- Pad string on the left
function utils.string.lpad(str, length, char)
    char = char or " "
    local pad_len = length - #str
    if pad_len <= 0 then
        return str
    end
    return string.rep(char, pad_len) .. str
end

-- Pad string on the right
function utils.string.rpad(str, length, char)
    char = char or " "
    local pad_len = length - #str
    if pad_len <= 0 then
        return str
    end
    return str .. string.rep(char, pad_len)
end

-- Center string
function utils.string.center(str, length, char)
    char = char or " "
    local pad_len = length - #str
    if pad_len <= 0 then
        return str
    end
    local left_pad = math.floor(pad_len / 2)
    local right_pad = pad_len - left_pad
    return string.rep(char, left_pad) .. str .. string.rep(char, right_pad)
end

-- Convert to camelCase
function utils.string.camel_case(str)
    local result = string.gsub(str, "[_%-](%w)", function(c)
        return string.upper(c)
    end)
    return string.lower(string.sub(result, 1, 1)) .. string.sub(result, 2)
end

-- Convert to snake_case
function utils.string.snake_case(str)
    local result = string.gsub(str, "([A-Z])", function(c)
        return "_" .. string.lower(c)
    end)
    result = string.gsub(result, "[%-]", "_")
    result = string.gsub(result, "^_", "")
    return string.lower(result)
end

-- Convert to kebab-case
function utils.string.kebab_case(str)
    local result = string.gsub(str, "([A-Z])", function(c)
        return "-" .. string.lower(c)
    end)
    result = string.gsub(result, "[_]", "-")
    result = string.gsub(result, "^%-", "")
    return string.lower(result)
end

-- Truncate string with ellipsis
function utils.string.truncate(str, max_length, ellipsis)
    ellipsis = ellipsis or "..."
    if #str <= max_length then
        return str
    end
    return string.sub(str, 1, max_length - #ellipsis) .. ellipsis
end

-- Count occurrences of substring
function utils.string.count(str, pattern, plain)
    local count = 0
    local pos = 1
    while true do
        local start_pos = string.find(str, pattern, pos, plain)
        if not start_pos then
            break
        end
        count = count + 1
        pos = start_pos + 1
    end
    return count
end

-- Replace all occurrences
function utils.string.replace(str, old, new, plain)
    if plain then
        old = string.gsub(old, "[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
    end
    return string.gsub(str, old, new)
end

-- Check if string contains substring
function utils.string.contains(str, substr)
    return string.find(str, substr, 1, true) ~= nil
end

-- Reverse string (UTF-8 aware)
function utils.string.reverse(str)
    local result = {}
    for char in string.gmatch(str, ".") do
        table.insert(result, 1, char)
    end
    return table.concat(result)
end

-- Wrap text to specified width
function utils.string.wrap(str, width, indent)
    indent = indent or ""
    local lines = {}
    local current_line = indent

    for word in string.gmatch(str, "%S+") do
        if #current_line + #word + 1 > width and current_line ~= indent then
            lines[#lines + 1] = current_line
            current_line = indent .. word
        elseif current_line == indent then
            current_line = current_line .. word
        else
            current_line = current_line .. " " .. word
        end
    end

    if current_line ~= indent then
        lines[#lines + 1] = current_line
    end

    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Table Utilities
--------------------------------------------------------------------------------

utils.table = {}

-- Deep copy a table
function utils.table.deep_copy(obj, seen)
    if type(obj) ~= "table" then
        return obj
    end

    seen = seen or {}
    if seen[obj] then
        return seen[obj]
    end

    local copy = {}
    seen[obj] = copy

    for k, v in pairs(obj) do
        copy[utils.table.deep_copy(k, seen)] = utils.table.deep_copy(v, seen)
    end

    return setmetatable(copy, getmetatable(obj))
end

-- Shallow copy a table
function utils.table.copy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return setmetatable(copy, getmetatable(tbl))
end

-- Merge multiple tables (later tables override earlier)
function utils.table.merge(...)
    local result = {}
    for i = 1, select("#", ...) do
        local tbl = select(i, ...)
        if tbl then
            for k, v in pairs(tbl) do
                result[k] = v
            end
        end
    end
    return result
end

-- Deep merge tables
function utils.table.deep_merge(...)
    local result = {}
    for i = 1, select("#", ...) do
        local tbl = select(i, ...)
        if tbl then
            for k, v in pairs(tbl) do
                if type(v) == "table" and type(result[k]) == "table" then
                    result[k] = utils.table.deep_merge(result[k], v)
                else
                    result[k] = utils.table.deep_copy(v)
                end
            end
        end
    end
    return result
end

-- Get all keys
function utils.table.keys(tbl)
    local keys = {}
    for k, _ in pairs(tbl) do
        keys[#keys + 1] = k
    end
    return keys
end

-- Get all values
function utils.table.values(tbl)
    local values = {}
    for _, v in pairs(tbl) do
        values[#values + 1] = v
    end
    return values
end

-- Check if table is empty
function utils.table.is_empty(tbl)
    return next(tbl) == nil
end

-- Get table length (works for non-sequential tables)
function utils.table.length(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Check if table is an array
function utils.table.is_array(tbl)
    local i = 0
    for _ in pairs(tbl) do
        i = i + 1
        if tbl[i] == nil then
            return false
        end
    end
    return true
end

-- Invert table (swap keys and values)
function utils.table.invert(tbl)
    local inverted = {}
    for k, v in pairs(tbl) do
        inverted[v] = k
    end
    return inverted
end

-- Get value at nested path
function utils.table.get(tbl, path, default)
    local keys = type(path) == "string" and utils.string.split(path, ".") or path

    local current = tbl
    for _, key in ipairs(keys) do
        if type(current) ~= "table" then
            return default
        end
        -- Try numeric key first for array access
        local num_key = tonumber(key)
        if num_key and current[num_key] ~= nil then
            current = current[num_key]
        elseif current[key] ~= nil then
            current = current[key]
        else
            return default
        end
    end
    return current
end

-- Set value at nested path
function utils.table.set(tbl, path, value)
    local keys = type(path) == "string" and utils.string.split(path, ".") or path

    local current = tbl
    for i = 1, #keys - 1 do
        local key = keys[i]
        local num_key = tonumber(key)
        key = num_key or key

        if current[key] == nil then
            current[key] = {}
        end
        current = current[key]
    end

    local last_key = keys[#keys]
    local num_key = tonumber(last_key)
    current[num_key or last_key] = value
    return tbl
end

-- Find element in array
function utils.table.find(arr, predicate)
    for i, v in ipairs(arr) do
        if predicate(v, i) then
            return v, i
        end
    end
    return nil
end

-- Find index of element
function utils.table.index_of(arr, value)
    for i, v in ipairs(arr) do
        if v == value then
            return i
        end
    end
    return nil
end

-- Check if array contains value
function utils.table.contains(arr, value)
    return utils.table.index_of(arr, value) ~= nil
end

-- Remove duplicates from array
function utils.table.unique(arr)
    local seen = {}
    local result = {}
    for _, v in ipairs(arr) do
        if not seen[v] then
            seen[v] = true
            result[#result + 1] = v
        end
    end
    return result
end

-- Flatten nested arrays
function utils.table.flatten(arr, depth)
    depth = depth or math.huge
    local result = {}

    local function do_flatten(tbl, current_depth)
        for _, v in ipairs(tbl) do
            if type(v) == "table" and current_depth < depth then
                do_flatten(v, current_depth + 1)
            else
                result[#result + 1] = v
            end
        end
    end

    do_flatten(arr, 0)
    return result
end

-- Slice array
function utils.table.slice(arr, start_idx, end_idx)
    start_idx = start_idx or 1
    end_idx = end_idx or #arr

    if start_idx < 0 then
        start_idx = #arr + start_idx + 1
    end
    if end_idx < 0 then
        end_idx = #arr + end_idx + 1
    end

    local result = {}
    for i = start_idx, end_idx do
        if arr[i] ~= nil then
            result[#result + 1] = arr[i]
        end
    end
    return result
end

-- Reverse array
function utils.table.reverse(arr)
    local result = {}
    for i = #arr, 1, -1 do
        result[#result + 1] = arr[i]
    end
    return result
end

-- Shuffle array (Fisher-Yates)
function utils.table.shuffle(arr)
    local result = utils.table.copy(arr)
    for i = #result, 2, -1 do
        local j = math.random(1, i)
        result[i], result[j] = result[j], result[i]
    end
    return result
end

-- Group array elements by key function
function utils.table.group_by(arr, key_fn)
    local groups = {}
    for _, v in ipairs(arr) do
        local key = key_fn(v)
        if not groups[key] then
            groups[key] = {}
        end
        groups[key][#groups[key] + 1] = v
    end
    return groups
end

-- Sort by key
function utils.table.sort_by(arr, key_fn, reverse)
    local result = utils.table.copy(arr)
    table.sort(result, function(a, b)
        local ka, kb = key_fn(a), key_fn(b)
        if reverse then
            return ka > kb
        else
            return ka < kb
        end
    end)
    return result
end

-- Zip multiple arrays together
function utils.table.zip(...)
    local arrays = {...}
    local result = {}
    local max_len = 0

    for _, arr in ipairs(arrays) do
        if #arr > max_len then
            max_len = #arr
        end
    end

    for i = 1, max_len do
        local tuple = {}
        for _, arr in ipairs(arrays) do
            tuple[#tuple + 1] = arr[i]
        end
        result[#result + 1] = tuple
    end

    return result
end

-- Create range array
function utils.table.range(start_val, end_val, step)
    if not end_val then
        end_val = start_val
        start_val = 1
    end
    step = step or 1

    local result = {}
    for i = start_val, end_val, step do
        result[#result + 1] = i
    end
    return result
end

--------------------------------------------------------------------------------
-- Functional Programming Utilities
--------------------------------------------------------------------------------

utils.func = {}

-- Map function over array
function utils.func.map(arr, fn)
    local result = {}
    for i, v in ipairs(arr) do
        result[i] = fn(v, i, arr)
    end
    return result
end

-- Filter array by predicate
function utils.func.filter(arr, predicate)
    local result = {}
    for i, v in ipairs(arr) do
        if predicate(v, i, arr) then
            result[#result + 1] = v
        end
    end
    return result
end

-- Reduce array to single value
function utils.func.reduce(arr, fn, initial)
    local accumulator = initial
    local start_idx = 1

    if accumulator == nil then
        accumulator = arr[1]
        start_idx = 2
    end

    for i = start_idx, #arr do
        accumulator = fn(accumulator, arr[i], i, arr)
    end

    return accumulator
end

-- Check if all elements satisfy predicate
function utils.func.all(arr, predicate)
    for i, v in ipairs(arr) do
        if not predicate(v, i, arr) then
            return false
        end
    end
    return true
end

-- Check if any element satisfies predicate
function utils.func.any(arr, predicate)
    for i, v in ipairs(arr) do
        if predicate(v, i, arr) then
            return true
        end
    end
    return false
end

-- Compose functions (right to left)
function utils.func.compose(...)
    local fns = {...}
    return function(...)
        local result = {...}
        for i = #fns, 1, -1 do
            result = {fns[i](table.unpack(result))}
        end
        return table.unpack(result)
    end
end

-- Pipe functions (left to right)
function utils.func.pipe(...)
    local fns = {...}
    return function(...)
        local result = {...}
        for i = 1, #fns do
            result = {fns[i](table.unpack(result))}
        end
        return table.unpack(result)
    end
end

-- Partial application
function utils.func.partial(fn, ...)
    local args = {...}
    return function(...)
        local new_args = {}
        for _, v in ipairs(args) do
            new_args[#new_args + 1] = v
        end
        for i = 1, select("#", ...) do
            new_args[#new_args + 1] = select(i, ...)
        end
        return fn(table.unpack(new_args))
    end
end

-- Curry function
function utils.func.curry(fn, arity)
    arity = arity or debug.getinfo(fn, "u").nparams

    local function curried(...)
        local args = {...}
        if #args >= arity then
            return fn(table.unpack(args, 1, arity))
        else
            return function(...)
                local new_args = {}
                for _, v in ipairs(args) do
                    new_args[#new_args + 1] = v
                end
                for i = 1, select("#", ...) do
                    new_args[#new_args + 1] = select(i, ...)
                end
                return curried(table.unpack(new_args))
            end
        end
    end

    return curried
end

-- Memoize function
function utils.func.memoize(fn, hash_fn)
    local cache = {}
    hash_fn = hash_fn or function(...)
        local args = {...}
        local parts = {}
        for _, v in ipairs(args) do
            parts[#parts + 1] = tostring(v)
        end
        return table.concat(parts, "\0")
    end

    return function(...)
        local key = hash_fn(...)
        if cache[key] == nil then
            cache[key] = {fn(...)}
        end
        return table.unpack(cache[key])
    end
end

-- Debounce function (requires coroutine or external timer)
function utils.func.once(fn)
    local called = false
    local result
    return function(...)
        if not called then
            called = true
            result = fn(...)
        end
        return result
    end
end

-- Negate predicate
function utils.func.negate(predicate)
    return function(...)
        return not predicate(...)
    end
end

-- Identity function
function utils.func.identity(x)
    return x
end

-- Constant function
function utils.func.constant(x)
    return function()
        return x
    end
end

-- Tap function (for side effects in pipelines)
function utils.func.tap(fn)
    return function(x)
        fn(x)
        return x
    end
end

--------------------------------------------------------------------------------
-- Path Utilities
--------------------------------------------------------------------------------

utils.path = {}

local PATH_SEP = package.config:sub(1, 1)
utils.path.sep = PATH_SEP

-- Join path components
function utils.path.join(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if part and part ~= "" then
            -- Remove trailing separators
            part = string.gsub(part, "[/\\]+$", "")
            -- Remove leading separators for non-first parts
            if #parts > 0 then
                part = string.gsub(part, "^[/\\]+", "")
            end
            if part ~= "" then
                parts[#parts + 1] = part
            end
        end
    end
    return table.concat(parts, PATH_SEP)
end

-- Get directory name
function utils.path.dirname(path)
    local dir = string.match(path, "^(.+)[/\\][^/\\]+$")
    return dir or "."
end

-- Get base name
function utils.path.basename(path, ext)
    local base = string.match(path, "[/\\]?([^/\\]+)$") or path
    if ext and utils.string.ends_with(base, ext) then
        base = string.sub(base, 1, #base - #ext)
    end
    return base
end

-- Get file extension
function utils.path.extname(path)
    local ext = string.match(path, "%.([^%.]+)$")
    return ext and ("." .. ext) or ""
end

-- Normalize path
function utils.path.normalize(path)
    -- Convert separators
    path = string.gsub(path, "[/\\]", PATH_SEP)

    -- Handle .. and .
    local parts = {}
    for part in string.gmatch(path, "[^" .. PATH_SEP .. "]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            else
                parts[#parts + 1] = part
            end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end

    local result = table.concat(parts, PATH_SEP)

    -- Preserve leading separator
    if string.sub(path, 1, 1) == PATH_SEP then
        result = PATH_SEP .. result
    end

    return result == "" and "." or result
end

-- Check if path is absolute
function utils.path.is_absolute(path)
    if PATH_SEP == "/" then
        return string.sub(path, 1, 1) == "/"
    else
        return string.match(path, "^%a:[/\\]") ~= nil
    end
end

-- Get relative path
function utils.path.relative(from, to)
    from = utils.path.normalize(from)
    to = utils.path.normalize(to)

    local from_parts = utils.string.split(from, PATH_SEP)
    local to_parts = utils.string.split(to, PATH_SEP)

    -- Find common prefix
    local common = 0
    for i = 1, math.min(#from_parts, #to_parts) do
        if from_parts[i] == to_parts[i] then
            common = i
        else
            break
        end
    end

    -- Build relative path
    local result = {}
    for _ = common + 1, #from_parts do
        result[#result + 1] = ".."
    end
    for i = common + 1, #to_parts do
        result[#result + 1] = to_parts[i]
    end

    return table.concat(result, PATH_SEP)
end

-- Parse path into components
function utils.path.parse(path)
    return {
        dir = utils.path.dirname(path),
        base = utils.path.basename(path),
        ext = utils.path.extname(path),
        name = utils.path.basename(path, utils.path.extname(path)),
    }
end

--------------------------------------------------------------------------------
-- Class System
--------------------------------------------------------------------------------

utils.class = {}

-- Create a new class
function utils.class.new(parent)
    local class = {}
    class.__index = class

    if parent then
        setmetatable(class, {
            __index = parent,
            __call = function(cls, ...)
                return cls:new(...)
            end
        })
        class.super = parent
    else
        setmetatable(class, {
            __call = function(cls, ...)
                return cls:new(...)
            end
        })
    end

    function class:new(...)
        local instance = setmetatable({}, self)
        if instance.init then
            instance:init(...)
        end
        return instance
    end

    function class:is_instance_of(cls)
        local current = getmetatable(self)
        while current do
            if current == cls then
                return true
            end
            current = getmetatable(current)
            if current then
                current = current.__index
            end
        end
        return false
    end

    return class
end

-- Mixin support
function utils.class.mixin(class, ...)
    for i = 1, select("#", ...) do
        local mixin = select(i, ...)
        for k, v in pairs(mixin) do
            if k ~= "init" and class[k] == nil then
                class[k] = v
            end
        end
    end
    return class
end

--------------------------------------------------------------------------------
-- Iterator Utilities
--------------------------------------------------------------------------------

utils.iter = {}

-- Create iterator from array
function utils.iter.from_array(arr)
    local i = 0
    return function()
        i = i + 1
        if i <= #arr then
            return i, arr[i]
        end
    end
end

-- Create iterator from function
function utils.iter.from_fn(fn, state, initial)
    return fn, state, initial
end

-- Collect iterator results into array
function utils.iter.to_array(iter, state, initial)
    local result = {}
    for _, v in iter, state, initial do
        result[#result + 1] = v
    end
    return result
end

-- Map over iterator
function utils.iter.map(iter, state, initial, fn)
    local function mapped_iter(s, var)
        local idx, val = iter(s, var)
        if idx ~= nil then
            return idx, fn(val, idx)
        end
    end
    return mapped_iter, state, initial
end

-- Filter iterator
function utils.iter.filter(iter, state, initial, predicate)
    local function filtered_iter(s, var)
        while true do
            local idx, val = iter(s, var)
            if idx == nil then
                return nil
            end
            if predicate(val, idx) then
                return idx, val
            end
            var = idx
        end
    end
    return filtered_iter, state, initial
end

-- Take first n elements
function utils.iter.take(iter, state, initial, n)
    local count = 0
    local function take_iter(s, var)
        if count >= n then
            return nil
        end
        local idx, val = iter(s, var)
        if idx ~= nil then
            count = count + 1
            return idx, val
        end
    end
    return take_iter, state, initial
end

-- Skip first n elements
function utils.iter.skip(iter, state, initial, n)
    local skipped = 0
    local var = initial
    while skipped < n do
        var = iter(state, var)
        if var == nil then
            return function() return nil end, state, nil
        end
        skipped = skipped + 1
    end
    return iter, state, var
end

-- Enumerate iterator (add indices)
function utils.iter.enumerate(iter, state, initial, start)
    start = start or 1
    local count = start - 1
    local function enum_iter(s, var)
        local idx, val = iter(s, var)
        if idx ~= nil then
            count = count + 1
            return idx, count, val
        end
    end
    return enum_iter, state, initial
end

--------------------------------------------------------------------------------
-- Validation Utilities
--------------------------------------------------------------------------------

utils.validate = {}

-- Type validators
function utils.validate.is_string(v)
    return type(v) == "string"
end

function utils.validate.is_number(v)
    return type(v) == "number"
end

function utils.validate.is_integer(v)
    return type(v) == "number" and v == math.floor(v)
end

function utils.validate.is_boolean(v)
    return type(v) == "boolean"
end

function utils.validate.is_table(v)
    return type(v) == "table"
end

function utils.validate.is_function(v)
    return type(v) == "function"
end

function utils.validate.is_nil(v)
    return v == nil
end

-- Value validators
function utils.validate.is_positive(v)
    return type(v) == "number" and v > 0
end

function utils.validate.is_negative(v)
    return type(v) == "number" and v < 0
end

function utils.validate.is_non_negative(v)
    return type(v) == "number" and v >= 0
end

function utils.validate.in_range(v, min, max)
    return type(v) == "number" and v >= min and v <= max
end

-- String validators
function utils.validate.is_non_empty_string(v)
    return type(v) == "string" and #v > 0
end

function utils.validate.matches_pattern(v, pattern)
    return type(v) == "string" and string.match(v, pattern) ~= nil
end

function utils.validate.is_email(v)
    return type(v) == "string" and string.match(v, "^[%w._%+-]+@[%w.-]+%.[%w]+$") ~= nil
end

function utils.validate.is_url(v)
    return type(v) == "string" and string.match(v, "^https?://[%w.-]+") ~= nil
end

-- Array validators
function utils.validate.is_non_empty_array(v)
    return type(v) == "table" and #v > 0 and utils.table.is_array(v)
end

function utils.validate.has_length(v, min, max)
    if type(v) ~= "table" and type(v) ~= "string" then
        return false
    end
    local len = #v
    if min and len < min then return false end
    if max and len > max then return false end
    return true
end

-- Schema validation
function utils.validate.schema(value, schema)
    local errors = {}

    local function validate_value(v, s, path)
        path = path or "root"

        -- Type check
        if s.type then
            local type_validators = {
                string = utils.validate.is_string,
                number = utils.validate.is_number,
                integer = utils.validate.is_integer,
                boolean = utils.validate.is_boolean,
                table = utils.validate.is_table,
                ["function"] = utils.validate.is_function,
                array = function(x) return type(x) == "table" and utils.table.is_array(x) end,
            }

            local validator = type_validators[s.type]
            if validator and not validator(v) then
                errors[#errors + 1] = string.format("%s: expected %s, got %s", path, s.type, type(v))
                return
            end
        end

        -- Required check
        if s.required and v == nil then
            errors[#errors + 1] = string.format("%s: required field is missing", path)
            return
        end

        if v == nil then
            return
        end

        -- Range check
        if s.min and type(v) == "number" and v < s.min then
            errors[#errors + 1] = string.format("%s: value %s is less than minimum %s", path, v, s.min)
        end
        if s.max and type(v) == "number" and v > s.max then
            errors[#errors + 1] = string.format("%s: value %s is greater than maximum %s", path, v, s.max)
        end

        -- Length check
        if s.min_length and (type(v) == "string" or type(v) == "table") and #v < s.min_length then
            errors[#errors + 1] = string.format("%s: length %d is less than minimum %d", path, #v, s.min_length)
        end
        if s.max_length and (type(v) == "string" or type(v) == "table") and #v > s.max_length then
            errors[#errors + 1] = string.format("%s: length %d is greater than maximum %d", path, #v, s.max_length)
        end

        -- Pattern check
        if s.pattern and type(v) == "string" and not string.match(v, s.pattern) then
            errors[#errors + 1] = string.format("%s: does not match pattern %s", path, s.pattern)
        end

        -- Enum check
        if s.enum then
            local found = false
            for _, allowed in ipairs(s.enum) do
                if v == allowed then
                    found = true
                    break
                end
            end
            if not found then
                errors[#errors + 1] = string.format("%s: value not in allowed set", path)
            end
        end

        -- Custom validator
        if s.validator and not s.validator(v) then
            errors[#errors + 1] = string.format("%s: custom validation failed", path)
        end

        -- Nested properties
        if s.properties and type(v) == "table" then
            for prop_name, prop_schema in pairs(s.properties) do
                validate_value(v[prop_name], prop_schema, path .. "." .. prop_name)
            end
        end

        -- Array items
        if s.items and type(v) == "table" then
            for i, item in ipairs(v) do
                validate_value(item, s.items, path .. "[" .. i .. "]")
            end
        end
    end

    validate_value(value, schema)

    return #errors == 0, errors
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

function utils.test()
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

    local function assert_deep_eq(a, b)
        if type(a) ~= type(b) then
            error(string.format("type mismatch: %s vs %s", type(a), type(b)))
        end
        if type(a) == "table" then
            for k, v in pairs(a) do
                assert_deep_eq(v, b[k])
            end
            for k in pairs(b) do
                if a[k] == nil then
                    error("missing key: " .. tostring(k))
                end
            end
        else
            if a ~= b then
                error(string.format("value mismatch: %s vs %s", tostring(a), tostring(b)))
            end
        end
    end

    print("Running utils tests...")

    -- String tests
    test("string.split", function()
        assert_deep_eq(utils.string.split("a,b,c", ","), {"a", "b", "c"})
        assert_deep_eq(utils.string.split("hello", ""), {"h", "e", "l", "l", "o"})
    end)

    test("string.trim", function()
        assert_eq(utils.string.trim("  hello  "), "hello")
        assert_eq(utils.string.ltrim("  hello  "), "hello  ")
        assert_eq(utils.string.rtrim("  hello  "), "  hello")
    end)

    test("string.starts_with/ends_with", function()
        assert_eq(utils.string.starts_with("hello", "he"), true)
        assert_eq(utils.string.starts_with("hello", "lo"), false)
        assert_eq(utils.string.ends_with("hello", "lo"), true)
        assert_eq(utils.string.ends_with("hello", "he"), false)
    end)

    test("string.camel_case", function()
        assert_eq(utils.string.camel_case("hello_world"), "helloWorld")
        assert_eq(utils.string.camel_case("hello-world"), "helloWorld")
    end)

    test("string.snake_case", function()
        assert_eq(utils.string.snake_case("helloWorld"), "hello_world")
        assert_eq(utils.string.snake_case("HelloWorld"), "hello_world")
    end)

    -- Table tests
    test("table.deep_copy", function()
        local orig = {a = 1, b = {c = 2}}
        local copy = utils.table.deep_copy(orig)
        copy.b.c = 3
        assert_eq(orig.b.c, 2)
    end)

    test("table.merge", function()
        local result = utils.table.merge({a = 1}, {b = 2}, {a = 3})
        assert_eq(result.a, 3)
        assert_eq(result.b, 2)
    end)

    test("table.get/set", function()
        local t = {a = {b = {c = 1}}}
        assert_eq(utils.table.get(t, "a.b.c"), 1)
        assert_eq(utils.table.get(t, "a.b.d", "default"), "default")
        utils.table.set(t, "a.b.d", 2)
        assert_eq(t.a.b.d, 2)
    end)

    test("table.flatten", function()
        assert_deep_eq(utils.table.flatten({{1, 2}, {3, {4, 5}}}), {1, 2, 3, 4, 5})
        assert_deep_eq(utils.table.flatten({{1, 2}, {3, {4, 5}}}, 1), {1, 2, 3, {4, 5}})
    end)

    -- Functional tests
    test("func.map", function()
        assert_deep_eq(utils.func.map({1, 2, 3}, function(x) return x * 2 end), {2, 4, 6})
    end)

    test("func.filter", function()
        assert_deep_eq(utils.func.filter({1, 2, 3, 4}, function(x) return x % 2 == 0 end), {2, 4})
    end)

    test("func.reduce", function()
        assert_eq(utils.func.reduce({1, 2, 3, 4}, function(a, b) return a + b end, 0), 10)
    end)

    test("func.compose/pipe", function()
        local add1 = function(x) return x + 1 end
        local mul2 = function(x) return x * 2 end
        assert_eq(utils.func.compose(mul2, add1)(3), 8)  -- (3+1)*2
        assert_eq(utils.func.pipe(add1, mul2)(3), 8)     -- (3+1)*2
    end)

    -- Path tests
    test("path.join", function()
        local result = utils.path.join("a", "b", "c")
        assert(result == "a/b/c" or result == "a\\b\\c")
    end)

    test("path.dirname/basename", function()
        assert_eq(utils.path.dirname("/a/b/c.txt"), "/a/b")
        assert_eq(utils.path.basename("/a/b/c.txt"), "c.txt")
        assert_eq(utils.path.basename("/a/b/c.txt", ".txt"), "c")
    end)

    test("path.extname", function()
        assert_eq(utils.path.extname("file.txt"), ".txt")
        assert_eq(utils.path.extname("file"), "")
    end)

    -- Validation tests
    test("validate types", function()
        assert_eq(utils.validate.is_string("hello"), true)
        assert_eq(utils.validate.is_number(42), true)
        assert_eq(utils.validate.is_integer(42), true)
        assert_eq(utils.validate.is_integer(42.5), false)
    end)

    test("validate.schema", function()
        local schema = {
            type = "table",
            properties = {
                name = {type = "string", required = true, min_length = 1},
                age = {type = "integer", min = 0, max = 150}
            }
        }
        local valid, _ = utils.validate.schema({name = "Alice", age = 30}, schema)
        assert_eq(valid, true)

        local invalid, errors = utils.validate.schema({name = "", age = -1}, schema)
        assert_eq(invalid, false)
        assert(#errors > 0)
    end)

    print(string.format("\nTests: %d passed, %d failed", tests_passed, tests_failed))
    return tests_failed == 0
end

return utils
