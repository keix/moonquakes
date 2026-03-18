--[[
  class.lua - Simple class system for Lua

  Copyright (c) 2025 Kei Sawamura
  Licensed under the MIT License. See LICENSE file in project root.

  Usage:
    local class = require("std.class")

    -- Basic class
    local Animal = class()
    function Animal:init(name)
        self.name = name
    end
    function Animal:speak()
        print(self.name .. " makes a sound")
    end

    -- Inheritance
    local Dog = class(Animal)
    function Dog:init(name, breed)
        Dog.super.init(self, name)  -- call parent init
        self.breed = breed
    end
    function Dog:speak()
        print(self.name .. " barks!")
    end

    -- Instantiation
    local dog = Dog("Rex", "German Shepherd")
    dog:speak()  --> "Rex barks!"

    -- Type checking
    print(dog:is_a(Dog))     --> true
    print(dog:is_a(Animal))  --> true

    -- Mixins
    local Swimmer = { swim = function(self) print(self.name .. " swims") end }
    local Duck = class(Animal):mixin(Swimmer)
]]

local function class(parent)
    local cls = {}
    cls.__index = cls
    cls.__class = cls

    -- Inheritance setup
    if parent then
        cls.super = parent
        setmetatable(cls, {
            __index = parent,
            __call = function(c, ...)
                return c:new(...)
            end
        })
    else
        setmetatable(cls, {
            __call = function(c, ...)
                return c:new(...)
            end
        })
    end

    -- Constructor
    function cls:new(...)
        local instance = setmetatable({}, self)
        if instance.init then
            instance:init(...)
        end
        return instance
    end

    -- Type checking
    function cls:is_a(klass)
        local mt = getmetatable(self)
        while mt do
            if mt.__class == klass then
                return true
            end
            mt = mt.__class and mt.__class.super
        end
        return false
    end

    -- Get class of instance
    function cls:class()
        return self.__class
    end

    -- Mixin support
    function cls:mixin(...)
        for i = 1, select("#", ...) do
            local mixin = select(i, ...)
            for k, v in pairs(mixin) do
                if k ~= "init" and self[k] == nil then
                    self[k] = v
                end
            end
        end
        return self
    end

    -- Clone instance
    function cls:clone()
        local copy = setmetatable({}, getmetatable(self))
        for k, v in pairs(self) do
            copy[k] = v
        end
        return copy
    end

    -- String representation
    function cls:__tostring()
        local name = self.__name or "instance"
        return string.format("<%s: %p>", name, self)
    end

    return cls
end

--------------------------------------------------------------------------------
-- Abstract class support
--------------------------------------------------------------------------------

-- Create abstract method placeholder
local function abstract(name)
    return function(self, ...)
        error(string.format("abstract method '%s' must be implemented", name), 2)
    end
end

-- Create a class with required abstract methods
local function abstract_class(parent)
    local cls = class(parent)
    cls.__abstract_methods = {}

    local original_new = cls.new
    function cls:new(...)
        -- Check abstract methods are implemented
        for method_name in pairs(self.__abstract_methods) do
            if self[method_name] == self.__abstract_methods[method_name] then
                error(string.format("cannot instantiate: abstract method '%s' not implemented", method_name), 2)
            end
        end
        return original_new(self, ...)
    end

    return cls
end

--------------------------------------------------------------------------------
-- Interface support
--------------------------------------------------------------------------------

local function interface(...)
    local methods = {...}
    local iface = {
        __methods = methods,
    }

    function iface:implemented_by(cls)
        for _, method in ipairs(self.__methods) do
            if type(cls[method]) ~= "function" then
                return false, method
            end
        end
        return true
    end

    function iface:check(cls)
        local ok, missing = self:implemented_by(cls)
        if not ok then
            error(string.format("class does not implement interface: missing '%s'", missing), 2)
        end
        return cls
    end

    return iface
end

--------------------------------------------------------------------------------
-- Singleton pattern
--------------------------------------------------------------------------------

local function singleton(parent)
    local cls = class(parent)
    local instance = nil

    local original_new = cls.new
    function cls:new(...)
        if instance then
            return instance
        end
        instance = original_new(self, ...)
        return instance
    end

    function cls:instance()
        return instance
    end

    function cls:reset()
        instance = nil
    end

    return cls
end

--------------------------------------------------------------------------------
-- Property support (getters/setters)
--------------------------------------------------------------------------------

local function property(getter, setter)
    return {
        __property = true,
        get = getter,
        set = setter,
    }
end

local function with_properties(cls)
    local original_index = cls.__index
    local original_newindex = cls.__newindex

    cls.__index = function(self, key)
        local prop = rawget(cls, "_props") and cls._props[key]
        if prop and prop.__property and prop.get then
            return prop.get(self)
        end
        if type(original_index) == "function" then
            return original_index(self, key)
        elseif type(original_index) == "table" then
            return original_index[key]
        end
    end

    cls.__newindex = function(self, key, value)
        local prop = rawget(cls, "_props") and cls._props[key]
        if prop and prop.__property then
            if prop.set then
                prop.set(self, value)
            else
                error(string.format("property '%s' is read-only", key), 2)
            end
            return
        end
        if original_newindex then
            original_newindex(self, key, value)
        else
            rawset(self, key, value)
        end
    end

    function cls:define_property(name, getter, setter)
        if not rawget(self, "_props") then
            rawset(self, "_props", {})
        end
        self._props[name] = property(getter, setter)
    end

    return cls
end

--------------------------------------------------------------------------------
-- Event mixin
--------------------------------------------------------------------------------

local EventMixin = {}

function EventMixin:on(event, handler)
    self._events = self._events or {}
    self._events[event] = self._events[event] or {}
    table.insert(self._events[event], handler)
    return self
end

function EventMixin:off(event, handler)
    if not self._events or not self._events[event] then
        return self
    end
    if handler then
        for i, h in ipairs(self._events[event]) do
            if h == handler then
                table.remove(self._events[event], i)
                break
            end
        end
    else
        self._events[event] = nil
    end
    return self
end

function EventMixin:emit(event, ...)
    if not self._events or not self._events[event] then
        return self
    end
    for _, handler in ipairs(self._events[event]) do
        handler(self, ...)
    end
    return self
end

function EventMixin:once(event, handler)
    local wrapper
    wrapper = function(...)
        self:off(event, wrapper)
        handler(...)
    end
    return self:on(event, wrapper)
end

--------------------------------------------------------------------------------
-- Observable mixin (for reactive properties)
--------------------------------------------------------------------------------

local ObservableMixin = {}

function ObservableMixin:observe(prop, handler)
    self._observers = self._observers or {}
    self._observers[prop] = self._observers[prop] or {}
    table.insert(self._observers[prop], handler)
    return self
end

function ObservableMixin:set(prop, value)
    local old = self[prop]
    if old == value then return self end

    rawset(self, prop, value)

    if self._observers and self._observers[prop] then
        for _, handler in ipairs(self._observers[prop]) do
            handler(self, value, old)
        end
    end
    return self
end

--------------------------------------------------------------------------------
-- Struct (simple data class)
--------------------------------------------------------------------------------

local function struct(fields)
    local cls = class()
    cls.__fields = fields

    function cls:init(values)
        values = values or {}
        for _, field in ipairs(fields) do
            local name, default
            if type(field) == "table" then
                name = field[1] or field.name
                default = field[2] or field.default
            else
                name = field
                default = nil
            end
            if values[name] ~= nil then
                self[name] = values[name]
            else
                self[name] = default
            end
        end
    end

    function cls:__tostring()
        local parts = {}
        for _, field in ipairs(fields) do
            local name = type(field) == "table" and (field[1] or field.name) or field
            parts[#parts + 1] = string.format("%s=%s", name, tostring(self[name]))
        end
        return string.format("{%s}", table.concat(parts, ", "))
    end

    function cls:__eq(other)
        if not other or getmetatable(other) ~= getmetatable(self) then
            return false
        end
        for _, field in ipairs(fields) do
            local name = type(field) == "table" and (field[1] or field.name) or field
            if self[name] ~= other[name] then
                return false
            end
        end
        return true
    end

    function cls:to_table()
        local t = {}
        for _, field in ipairs(fields) do
            local name = type(field) == "table" and (field[1] or field.name) or field
            t[name] = self[name]
        end
        return t
    end

    return cls
end

--------------------------------------------------------------------------------
-- Enum
--------------------------------------------------------------------------------

local function enum(values)
    local e = {}
    local reverse = {}

    for i, name in ipairs(values) do
        e[name] = i
        reverse[i] = name
    end

    return setmetatable(e, {
        __index = function(_, key)
            if type(key) == "number" then
                return reverse[key]
            end
            error(string.format("invalid enum value: %s", tostring(key)), 2)
        end,
        __newindex = function()
            error("cannot modify enum", 2)
        end,
        __call = function(_, value)
            if type(value) == "number" then
                return reverse[value]
            elseif type(value) == "string" then
                return e[value]
            end
        end,
        __pairs = function()
            return pairs(reverse)
        end,
    })
end

--------------------------------------------------------------------------------
-- Self-test
--------------------------------------------------------------------------------

local function test()
    local tests_passed = 0
    local tests_failed = 0

    local function test_case(name, fn)
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

    print("Running class tests...")

    test_case("basic class", function()
        local A = class()
        function A:init(x) self.x = x end
        function A:get() return self.x end

        local a = A(42)
        assert_eq(a.x, 42)
        assert_eq(a:get(), 42)
    end)

    test_case("inheritance", function()
        local Animal = class()
        function Animal:init(name) self.name = name end
        function Animal:speak() return "..." end

        local Dog = class(Animal)
        function Dog:speak() return "woof" end

        local dog = Dog("Rex")
        assert_eq(dog.name, "Rex")
        assert_eq(dog:speak(), "woof")
    end)

    test_case("super call", function()
        local Base = class()
        function Base:init(x) self.x = x end
        function Base:value() return self.x end

        local Child = class(Base)
        function Child:init(x, y)
            Child.super.init(self, x)
            self.y = y
        end
        function Child:value()
            return Child.super.value(self) + self.y
        end

        local c = Child(10, 5)
        assert_eq(c.x, 10)
        assert_eq(c.y, 5)
        assert_eq(c:value(), 15)
    end)

    test_case("is_a check", function()
        local A = class()
        local B = class(A)
        local C = class(B)
        local D = class()

        local c = C()
        assert_eq(c:is_a(C), true)
        assert_eq(c:is_a(B), true)
        assert_eq(c:is_a(A), true)
        assert_eq(c:is_a(D), false)
    end)

    test_case("mixin", function()
        local Swimmer = {
            swim = function(self) return self.name .. " swims" end
        }
        local Flyer = {
            fly = function(self) return self.name .. " flies" end
        }

        local Duck = class():mixin(Swimmer, Flyer)
        function Duck:init(name) self.name = name end

        local duck = Duck("Donald")
        assert_eq(duck:swim(), "Donald swims")
        assert_eq(duck:fly(), "Donald flies")
    end)

    test_case("clone", function()
        local Point = class()
        function Point:init(x, y) self.x, self.y = x, y end

        local p1 = Point(10, 20)
        local p2 = p1:clone()
        p2.x = 30

        assert_eq(p1.x, 10)
        assert_eq(p2.x, 30)
    end)

    test_case("interface", function()
        local Drawable = interface("draw", "resize")

        local Shape = class()
        function Shape:draw() end
        function Shape:resize() end

        local ok = Drawable:implemented_by(Shape)
        assert_eq(ok, true)

        local Bad = class()
        local ok2, missing = Drawable:implemented_by(Bad)
        assert_eq(ok2, false)
        assert_eq(missing, "draw")
    end)

    test_case("singleton", function()
        local Config = singleton()
        function Config:init() self.data = {} end

        local c1 = Config()
        c1.data.key = "value"

        local c2 = Config()
        assert_eq(c1, c2)
        assert_eq(c2.data.key, "value")

        Config:reset()
        local c3 = Config()
        assert_eq(c3.data.key, nil)
    end)

    test_case("struct", function()
        local Point = struct({"x", "y"})
        local p1 = Point({x = 10, y = 20})
        local p2 = Point({x = 10, y = 20})
        local p3 = Point({x = 30, y = 40})

        assert_eq(p1.x, 10)
        assert_eq(p1.y, 20)
        assert_eq(p1 == p2, true)
        assert_eq(p1 == p3, false)
    end)

    test_case("struct with defaults", function()
        local Config = struct({
            {"host", "localhost"},
            {"port", 8080},
        })

        local c = Config({port = 3000})
        assert_eq(c.host, "localhost")
        assert_eq(c.port, 3000)
    end)

    test_case("enum", function()
        local Color = enum({"RED", "GREEN", "BLUE"})

        assert_eq(Color.RED, 1)
        assert_eq(Color.GREEN, 2)
        assert_eq(Color(1), "RED")
        assert_eq(Color("BLUE"), 3)
    end)

    test_case("event mixin", function()
        local Button = class():mixin(EventMixin)
        function Button:init(label) self.label = label end
        function Button:click() self:emit("click", self.label) end

        local btn = Button("OK")
        local clicked = nil
        btn:on("click", function(_, label) clicked = label end)
        btn:click()

        assert_eq(clicked, "OK")
    end)

    test_case("observable mixin", function()
        local Model = class():mixin(ObservableMixin)
        function Model:init() self.value = 0 end

        local m = Model()
        local changes = {}
        m:observe("value", function(_, new, old)
            table.insert(changes, {new = new, old = old})
        end)

        m:set("value", 10)
        m:set("value", 20)

        assert_eq(#changes, 2)
        assert_eq(changes[1].old, 0)
        assert_eq(changes[1].new, 10)
        assert_eq(changes[2].old, 10)
        assert_eq(changes[2].new, 20)
    end)

    print(string.format("\nTests: %d passed, %d failed", tests_passed, tests_failed))
    return tests_failed == 0
end

--------------------------------------------------------------------------------
-- Module export
--------------------------------------------------------------------------------

return setmetatable({
    class = class,
    abstract = abstract,
    abstract_class = abstract_class,
    interface = interface,
    singleton = singleton,
    struct = struct,
    enum = enum,
    property = property,
    with_properties = with_properties,

    -- Mixins
    EventMixin = EventMixin,
    ObservableMixin = ObservableMixin,

    -- Testing
    test = test,
}, {
    -- Allow direct call: local class = require("std.class"); local A = class()
    __call = function(_, parent)
        return class(parent)
    end
})
