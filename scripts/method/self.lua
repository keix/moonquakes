-- Test SELF opcode and method call syntax

-- Test 1: Basic method call
local obj = {
    value = 42,
    getValue = function(self)
        return self.value
    end,
    add = function(self, n)
        return self.value + n
    end,
    setValue = function(self, v)
        self.value = v
    end
}

local v = obj:getValue()
assert(v == 42, "getValue should return 42")

-- Test 2: Method call with argument
local v2 = obj:add(8)
assert(v2 == 50, "add(8) should return 50")

-- Test 3: Method modifying self
obj:setValue(100)
assert(obj.value == 100, "value should be 100 after setValue")
assert(obj:getValue() == 100, "getValue should return 100")

-- Test 4: Chained field + method call (t.a:method())
local container = {
    inner = {
        data = "hello",
        getData = function(self)
            return self.data
        end
    }
}

local result = container.inner:getData()
assert(result == "hello", "chained method should return 'hello'")

-- Test 5: Method returning self for chaining
local builder = {
    parts = {},
    addPart = function(self, part)
        table.insert(self.parts, part)
        return self
    end,
    build = function(self)
        return table.concat(self.parts, "-")
    end
}

local built = builder:addPart("a"):addPart("b"):addPart("c"):build()
assert(built == "a-b-c", "builder should produce 'a-b-c'")

print("self test passed")
