--[[
  path.lua - File path manipulation

  Copyright (c) 2025 Kei Sawamura
  Licensed under the MIT License. See LICENSE file in project root.

  Usage:
    local path = require("std.path")

    path.join("a", "b", "c")      --> "a/b/c"
    path.basename("/a/b/c.txt")   --> "c.txt"
    path.dirname("/a/b/c.txt")    --> "/a/b"
    path.extname("file.txt")      --> ".txt"
    path.normalize("a/../b/./c")  --> "b/c"

  Platform:
    Automatically detects path separator from package.config
    Works on both Unix and Windows
]]

local path = {}

--------------------------------------------------------------------------------
-- Platform detection
--------------------------------------------------------------------------------

path.sep = package.config:sub(1, 1)
path.is_windows = path.sep == "\\"
path.delimiter = path.is_windows and ";" or ":"

--------------------------------------------------------------------------------
-- Core functions
--------------------------------------------------------------------------------

-- Join path components
function path.join(...)
    local parts = {}

    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if part and part ~= "" then
            -- Normalize separators
            part = part:gsub("[/\\]", path.sep)
            -- Remove trailing separators (except for root)
            if #part > 1 then
                part = part:gsub("[/\\]+$", "")
            end
            -- Remove leading separators for non-first parts
            if #parts > 0 then
                part = part:gsub("^[/\\]+", "")
            end
            if part ~= "" then
                parts[#parts + 1] = part
            end
        end
    end

    local result = table.concat(parts, path.sep)

    -- Normalize multiple separators
    result = result:gsub("[/\\]+", path.sep)

    return result
end

-- Get directory name
function path.dirname(p)
    if not p or p == "" then
        return "."
    end

    -- Normalize separators
    p = p:gsub("[/\\]", path.sep)

    -- Remove trailing separator
    p = p:gsub("[/\\]+$", "")

    -- Handle root
    if p == "" then
        return path.sep
    end

    -- Find last separator
    local dir = p:match("^(.*)[/\\][^/\\]+$")

    if not dir then
        return "."
    elseif dir == "" then
        return path.sep
    else
        return dir
    end
end

-- Get base name (filename)
function path.basename(p, ext)
    if not p or p == "" then
        return ""
    end

    -- Normalize and remove trailing separator
    p = p:gsub("[/\\]+$", "")

    -- Extract basename
    local base = p:match("[/\\]?([^/\\]+)$") or p

    -- Remove extension if specified
    if ext and ext ~= "" then
        if base:sub(-#ext) == ext then
            base = base:sub(1, -#ext - 1)
        end
    end

    return base
end

-- Get file extension (including dot)
function path.extname(p)
    if not p then
        return ""
    end

    local base = path.basename(p)

    -- Handle dotfiles (.gitignore -> "")
    if base:sub(1, 1) == "." then
        local ext = base:match("%.([^%.]+)$", 2)
        return ext and ("." .. ext) or ""
    end

    local ext = base:match("%.([^%.]+)$")
    return ext and ("." .. ext) or ""
end

-- Get filename without extension
function path.stem(p)
    local base = path.basename(p)
    local ext = path.extname(p)
    if ext == "" then
        return base
    end
    return base:sub(1, -#ext - 1)
end

-- Normalize path (resolve . and ..)
function path.normalize(p)
    if not p or p == "" then
        return "."
    end

    -- Normalize separators
    p = p:gsub("[/\\]", path.sep)

    -- Track if absolute
    local is_abs = path.is_absolute(p)
    local prefix = ""

    if is_abs then
        if path.is_windows then
            -- Handle drive letter
            local drive = p:match("^(%a:)")
            if drive then
                prefix = drive
                p = p:sub(3)
            end
        end
        prefix = prefix .. path.sep
        p = p:gsub("^[/\\]+", "")
    end

    -- Split and process
    local parts = {}
    for part in p:gmatch("[^/\\]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif not is_abs then
                parts[#parts + 1] = ".."
            end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end

    local result = prefix .. table.concat(parts, path.sep)

    if result == "" then
        return is_abs and path.sep or "."
    end

    return result
end

-- Check if path is absolute
function path.is_absolute(p)
    if not p or p == "" then
        return false
    end

    if path.is_windows then
        -- Windows: starts with drive letter or UNC
        return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\]") ~= nil
    else
        -- Unix: starts with /
        return p:sub(1, 1) == "/"
    end
end

-- Check if path is relative
function path.is_relative(p)
    return not path.is_absolute(p)
end

-- Get relative path from one path to another
function path.relative(from, to)
    from = path.normalize(from)
    to = path.normalize(to)

    -- Must both be absolute or both be relative
    if path.is_absolute(from) ~= path.is_absolute(to) then
        return to
    end

    -- Split into parts
    local from_parts = {}
    for part in from:gmatch("[^/\\]+") do
        from_parts[#from_parts + 1] = part
    end

    local to_parts = {}
    for part in to:gmatch("[^/\\]+") do
        to_parts[#to_parts + 1] = part
    end

    -- Find common prefix length
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

    -- Add .. for each remaining from part
    for _ = common + 1, #from_parts do
        result[#result + 1] = ".."
    end

    -- Add remaining to parts
    for i = common + 1, #to_parts do
        result[#result + 1] = to_parts[i]
    end

    if #result == 0 then
        return "."
    end

    return table.concat(result, path.sep)
end

-- Resolve path (make absolute)
function path.resolve(...)
    local resolved = ""

    for i = select("#", ...), 1, -1 do
        local p = select(i, ...)
        if p and p ~= "" then
            resolved = path.join(p, resolved)
            if path.is_absolute(resolved) then
                break
            end
        end
    end

    -- If still relative, prepend current directory
    if not path.is_absolute(resolved) then
        -- Note: This requires io.popen or lfs for real cwd
        -- For now, just normalize
        resolved = path.normalize(resolved)
    end

    return path.normalize(resolved)
end

-- Parse path into components
function path.parse(p)
    return {
        root = path.is_absolute(p) and path.sep or "",
        dir = path.dirname(p),
        base = path.basename(p),
        ext = path.extname(p),
        name = path.stem(p),
    }
end

-- Format path from components
function path.format(obj)
    local dir = obj.dir or ""
    local base = obj.base

    if not base then
        local name = obj.name or ""
        local ext = obj.ext or ""
        base = name .. ext
    end

    if dir == "" then
        return base
    end

    return path.join(dir, base)
end

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

-- Check if path matches glob pattern
function path.match(p, pattern)
    -- Convert glob to Lua pattern
    local lua_pattern = pattern
        :gsub("([%.%+%-%^%$%(%)%%])", "%%%1")  -- Escape special chars
        :gsub("%*%*", "\0")                     -- Temporarily replace **
        :gsub("%*", "[^/\\]*")                  -- * matches non-separator
        :gsub("\0", ".*")                       -- ** matches anything
        :gsub("%?", "[^/\\]")                   -- ? matches single non-separator

    return p:match("^" .. lua_pattern .. "$") ~= nil
end

-- Split path into list of components
function path.split(p)
    local parts = {}
    p = p:gsub("[/\\]", path.sep)

    -- Handle root
    if path.is_absolute(p) then
        if path.is_windows then
            local drive = p:match("^(%a:)")
            if drive then
                parts[#parts + 1] = drive .. path.sep
                p = p:sub(4)
            else
                parts[#parts + 1] = path.sep
                p = p:gsub("^[/\\]+", "")
            end
        else
            parts[#parts + 1] = path.sep
            p = p:gsub("^/+", "")
        end
    end

    for part in p:gmatch("[^/\\]+") do
        parts[#parts + 1] = part
    end

    return parts
end

-- Get common prefix of multiple paths
function path.common(...)
    local paths = {...}
    if #paths == 0 then
        return ""
    end
    if #paths == 1 then
        return path.dirname(paths[1])
    end

    -- Split all paths
    local all_parts = {}
    for i, p in ipairs(paths) do
        all_parts[i] = path.split(p)
    end

    -- Find common prefix
    local common_parts = {}
    local min_len = math.huge
    for _, parts in ipairs(all_parts) do
        if #parts < min_len then
            min_len = #parts
        end
    end

    for i = 1, min_len do
        local part = all_parts[1][i]
        local all_same = true
        for j = 2, #all_parts do
            if all_parts[j][i] ~= part then
                all_same = false
                break
            end
        end
        if all_same then
            common_parts[#common_parts + 1] = part
        else
            break
        end
    end

    if #common_parts == 0 then
        return ""
    end

    -- Handle root separator specially
    if common_parts[1] == path.sep or common_parts[1] == "/" then
        if #common_parts == 1 then
            return path.sep
        end
        return path.sep .. table.concat(common_parts, path.sep, 2)
    end

    return table.concat(common_parts, path.sep)
end

-- Change file extension
function path.change_ext(p, new_ext)
    local ext = path.extname(p)
    if ext == "" then
        return p .. new_ext
    end
    return p:sub(1, -#ext - 1) .. new_ext
end

-- Ensure path ends with separator (for directories)
function path.ensure_dir(p)
    if p == "" then
        return "." .. path.sep
    end
    if p:sub(-1) ~= path.sep and p:sub(-1) ~= "/" and p:sub(-1) ~= "\\" then
        return p .. path.sep
    end
    return p
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

function path.test()
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
        -- Normalize for comparison (handle both separators)
        local na = type(a) == "string" and a:gsub("[/\\]", "/") or a
        local nb = type(b) == "string" and b:gsub("[/\\]", "/") or b
        if na ~= nb then
            error(string.format("%s: expected '%s', got '%s'", msg or "assertion failed", tostring(b), tostring(a)))
        end
    end

    print("Running path tests...")

    test("join basic", function()
        assert_eq(path.join("a", "b", "c"), "a/b/c")
        assert_eq(path.join("a/", "/b/", "/c"), "a/b/c")
        assert_eq(path.join("", "a", "", "b"), "a/b")
    end)

    test("dirname", function()
        assert_eq(path.dirname("/a/b/c.txt"), "/a/b")
        assert_eq(path.dirname("a/b/c"), "a/b")
        assert_eq(path.dirname("file.txt"), ".")
        assert_eq(path.dirname("/file.txt"), "/")
        assert_eq(path.dirname(""), ".")
    end)

    test("basename", function()
        assert_eq(path.basename("/a/b/c.txt"), "c.txt")
        assert_eq(path.basename("file.txt"), "file.txt")
        assert_eq(path.basename("/a/b/c.txt", ".txt"), "c")
        assert_eq(path.basename("a/b/"), "b")
    end)

    test("extname", function()
        assert_eq(path.extname("file.txt"), ".txt")
        assert_eq(path.extname("file.tar.gz"), ".gz")
        assert_eq(path.extname("file"), "")
        assert_eq(path.extname(".gitignore"), "")
        assert_eq(path.extname(".config.json"), ".json")
    end)

    test("stem", function()
        assert_eq(path.stem("file.txt"), "file")
        assert_eq(path.stem("file.tar.gz"), "file.tar")
        assert_eq(path.stem("file"), "file")
    end)

    test("normalize", function()
        assert_eq(path.normalize("a/b/../c"), "a/c")
        assert_eq(path.normalize("a/./b/./c"), "a/b/c")
        assert_eq(path.normalize("a//b///c"), "a/b/c")
        assert_eq(path.normalize("../a/b"), "../a/b")
        assert_eq(path.normalize("/a/../b"), "/b")
        assert_eq(path.normalize(""), ".")
    end)

    test("is_absolute", function()
        assert_eq(path.is_absolute("/a/b"), true)
        assert_eq(path.is_absolute("a/b"), false)
        assert_eq(path.is_absolute(""), false)
    end)

    test("relative", function()
        assert_eq(path.relative("/a/b/c", "/a/d/e"), "../../d/e")
        assert_eq(path.relative("/a/b", "/a/d/e"), "../d/e")
        assert_eq(path.relative("/a/b", "/a/b/c/d"), "c/d")
        assert_eq(path.relative("/a/b", "/a/b"), ".")
    end)

    test("parse", function()
        local p = path.parse("/home/user/file.txt")
        assert_eq(p.dir, "/home/user")
        assert_eq(p.base, "file.txt")
        assert_eq(p.ext, ".txt")
        assert_eq(p.name, "file")
    end)

    test("split", function()
        local parts = path.split("/a/b/c")
        assert_eq(parts[1], "/")
        assert_eq(parts[2], "a")
        assert_eq(parts[3], "b")
        assert_eq(parts[4], "c")
    end)

    test("match", function()
        assert_eq(path.match("file.lua", "*.lua"), true)
        assert_eq(path.match("file.txt", "*.lua"), false)
        assert_eq(path.match("a/b/c.lua", "**/*.lua"), true)
        assert_eq(path.match("test_file.lua", "test_*.lua"), true)
    end)

    test("change_ext", function()
        assert_eq(path.change_ext("file.txt", ".md"), "file.md")
        assert_eq(path.change_ext("file", ".txt"), "file.txt")
    end)

    test("common", function()
        assert_eq(path.common("/a/b/c", "/a/b/d", "/a/b/e"), "/a/b")
        assert_eq(path.common("/a/x", "/b/y"), "/")
    end)

    print(string.format("\nTests: %d passed, %d failed", tests_passed, tests_failed))
    return tests_failed == 0
end

return path
