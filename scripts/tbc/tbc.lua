-- Test to-be-closed (TBC) variables
-- Lua 5.4 feature: local <close> syntax

-- Create a closeable object
local function makeCloseable(name)
    return setmetatable({name = name, closed = false}, {
        __close = function(self, err)
            self.closed = true
        end
    })
end

-- Test 1: Basic TBC with normal scope exit
local obj1 = makeCloseable("obj1")
do
    local x <close> = obj1
    assert(not obj1.closed, "obj1 should not be closed yet")
end
assert(obj1.closed, "obj1 should be closed after scope exit")

-- Test 2: TBC with nil (should be no-op)
do
    local x <close> = nil
end

-- Test 3: TBC with false (should be no-op)
do
    local x <close> = false
end

-- Test 4: Multiple TBC variables (closed in reverse order)
local order = {}
local function makeOrderedCloseable(name)
    return setmetatable({name = name}, {
        __close = function(self)
            table.insert(order, self.name)
        end
    })
end

do
    local a <close> = makeOrderedCloseable("a")
    local b <close> = makeOrderedCloseable("b")
    local c <close> = makeOrderedCloseable("c")
end

assert(order[1] == "c", "c should close first")
assert(order[2] == "b", "b should close second")
assert(order[3] == "a", "a should close third")

-- Test 5: TBC in function return
local function makeFuncCloseable(name)
    return setmetatable({name = name, closed = false}, {
        __close = function(self, err)
            self.closed = true
        end
    })
end

local function testFunc()
    local obj = makeFuncCloseable("funcObj")
    local x <close> = obj
    return obj
end

local retObj = testFunc()
assert(retObj.closed, "TBC should close on function return")

print("tbc passed")
