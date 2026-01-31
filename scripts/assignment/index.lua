-- Index assignment: t[key] = value

function test()
    local t = {}
    local key = "x"
    t[key] = 42
    t["y"] = 100
    return t.x + t.y
end

return test()
