-- Package Library Tests
-- Can be run from project root or scripts/package directory

-- Adjust package.path to find test modules
local base = "scripts/package/"
package.path = "./" .. base .. "?.lua;./" .. base .. "?/init.lua;" .. package.path

local function test(name, cond)
    if cond then
        print("[PASS] " .. name)
    else
        print("[FAIL] " .. name)
        error("Test failed: " .. name)
    end
end

print("=== Package Library Tests ===")
print()

-- Test 1: package table exists
print("-- Basic package table --")
test("package exists", type(package) == "table")
test("package.path exists", type(package.path) == "string")
test("package.cpath exists", type(package.cpath) == "string")
test("package.config exists", type(package.config) == "string")
test("package.loaded exists", type(package.loaded) == "table")
test("package.preload exists", type(package.preload) == "table")
test("package.searchpath exists", type(package.searchpath) == "function")
test("package.loadlib exists", type(package.loadlib) == "function")
print()

-- Test 2: package.searchpath
print("-- package.searchpath --")
local search_path = "./" .. base .. "?.lua"
local found, err = package.searchpath("mylib", search_path)
test("searchpath finds mylib.lua", found == "./" .. base .. "mylib.lua")

found, err = package.searchpath("nonexistent", search_path)
test("searchpath returns nil for missing", found == nil)
test("searchpath returns error message", type(err) == "string")

-- Test dotted name replacement
found, err = package.searchpath("mylib.utils", search_path)
test("searchpath replaces dots with /", found == "./" .. base .. "mylib/utils.lua")
print()

-- Test 3: package.loadlib (should fail gracefully)
print("-- package.loadlib --")
local func, err = package.loadlib("libfoo.so", "init")
test("loadlib returns nil", func == nil)
test("loadlib returns error", type(err) == "string")
print()

-- Test 4: require simple module
print("-- require simple module --")
local mylib = require("mylib")
test("require returns table", type(mylib) == "table")
test("module has name", mylib.name == "mylib")
test("module has version", mylib.version == "1.0.0")
test("module function works", mylib.greet("Lua") == "Hello, Lua!")
test("module add works", mylib.add(2, 3) == 5)
print()

-- Test 5: require caches modules
print("-- require caching --")
local mylib2 = require("mylib")
test("require returns same object", mylib == mylib2)
test("module in package.loaded", package.loaded["mylib"] == mylib)
print()

-- Test 6: require dotted module name
print("-- require dotted module --")
local utils = require("mylib.utils")
test("dotted module loads", type(utils) == "table")
test("dotted module name", utils.name == "mylib.utils")
test("dotted module function", utils.double(21) == 42)
print()

-- Test 7: require directory module (init.lua)
print("-- require directory module (init.lua) --")
local nested = require("nested")
test("directory module loads", type(nested) == "table")
test("loaded via init.lua", nested.loaded_via == "init.lua")
test("directory module function", nested.info() ~= nil)
print()

-- Test 8: require deeply nested module
print("-- require deeply nested module --")
local deep = require("nested.deep.module")
test("deep module loads", type(deep) == "table")
test("deep module name", deep.name == "nested.deep.module")
test("deep module depth", deep.depth == 3)
print()

-- Test 9: package.preload
print("-- package.preload --")
package.preload["custom_module"] = function(modname)
    return {
        name = modname,
        preloaded = true,
        value = 100
    }
end
local custom = require("custom_module")
test("preload module loads", type(custom) == "table")
test("preload receives modname", custom.name == "custom_module")
test("preload flag set", custom.preloaded == true)
test("preload value", custom.value == 100)
print()

-- Test 10: require built-in modules
print("-- require built-in modules --")
local math_mod = require("math")
test("require math", type(math_mod) == "table")
test("math.pi exists", math_mod.pi ~= nil)

local string_mod = require("string")
test("require string", type(string_mod) == "table")
test("string.len exists", type(string_mod.len) == "function")

local table_mod = require("table")
test("require table", type(table_mod) == "table")
test("table.insert exists", type(table_mod.insert) == "function")
print()

-- Test 11: require error handling
print("-- require error handling --")
local ok, err = pcall(function()
    require("nonexistent_module_xyz")
end)
test("require nonexistent fails", ok == false)
test("error message mentions module", string.find(err, "nonexistent_module_xyz") ~= nil)
print()

print("=== All package tests passed! ===")
