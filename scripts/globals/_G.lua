-- Test _G global table access

-- _G should be a table
assert(type(_G) == "table", "_G should be a table")

-- _G should be the globals table (self-reference)
assert(_G._G == _G, "_G._G should equal _G")

-- Reading global variables through _G
x = 42
assert(_G.x == 42, "_G.x should be 42")

-- Writing global variables through _G
_G.y = 100
assert(y == 100, "y should be 100 after _G.y = 100")

-- Standard library functions should be accessible via _G
assert(_G.print == print, "_G.print should equal print")
assert(_G.assert == assert, "_G.assert should equal assert")
assert(_G.type == type, "_G.type should equal type")
assert(_G.tostring == tostring, "_G.tostring should equal tostring")

-- Library tables should be accessible via _G
assert(_G.string == string, "_G.string should equal string")
assert(_G.math == math, "_G.math should equal math")
assert(_G.table == table, "_G.table should equal table")
assert(_G.io == io, "_G.io should equal io")

-- Nested access through _G
assert(_G.string.len == string.len, "_G.string.len should equal string.len")
assert(_G.math.abs == math.abs, "_G.math.abs should equal math.abs")

-- Dynamic global access pattern
local name = "x"
-- Note: _G[name] requires index access which may or may not be supported
-- For now, just test field access

print("All _G tests passed!")
