-- Method call syntax: t:method(args)
local t = {
    x = 10,
    add = function(self, n)
        return self.x + n
    end
}
return t:add(5)
-- expect: 15
